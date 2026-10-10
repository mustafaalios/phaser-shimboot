// SPDX-License-Identifier: GPL-2.0
/*
 * shimboot_kexec - kexec_load as a loadable module for the octopus RMA shim kernel.
 *
 * The octopus shim kernel (Linux 4.14.91) is built without CONFIG_KEXEC_CORE, so the
 * kexec_load syscall returns -ENOSYS and /sys/kernel/kexec_loaded does not exist. The
 * firmware will only boot that signed kernel from USB, so it cannot be rebuilt. This
 * module adds the kexec machinery back at runtime:
 *
 *   - It carries a trimmed copy of the 4.14 kexec core (default kexec only; no kdump,
 *     no file-based load, no kexec-jump) plus the x86_64 relocate trampoline.
 *   - Unexported kernel internals it needs are resolved through kallsyms_lookup_name
 *     (4.14 still exports it). Only non-static globals are looked up, so this does not
 *     depend on CONFIG_KALLSYMS_ALL.
 *   - It hooks the kexec_load and reboot entries in sys_call_table, so the stock
 *     kexec-tools userspace binary already in the bootloader works unchanged:
 *     `kexec -l` -> our kexec_load, `kexec -e` -> reboot(LINUX_REBOOT_CMD_KEXEC) -> our path.
 *
 * The shim kernel does not enforce module signatures (it ships 293 unsigned modules),
 * and MODVERSIONS is off, so a module built against the matching chromeos-4.14 source
 * with the right vermagic loads. See kexec_mod/README.md for the full rationale and the
 * risks that can only be settled on the actual hardware.
 *
 * Derived from the Linux 4.14 kernel kexec implementation:
 *   kernel/kexec_core.c, kernel/kexec.c, arch/x86/kernel/machine_kexec_64.c
 * Copyright (C) 2002-2005 Eric Biederman <ebiederm@xmission.com>, GPL v2.
 */

#define pr_fmt(fmt) "shimboot_kexec: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/gfp.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/highmem.h>
#include <linux/uaccess.h>
#include <linux/capability.h>
#include <linux/kallsyms.h>
#include <linux/reboot.h>
#include <linux/preempt.h>
#include <linux/range.h>
#include <linux/vmalloc.h>
#include <linux/syscalls.h>
#include <asm/page.h>
#include <asm/pgtable.h>
#include <asm/tlbflush.h>
#include <asm/io.h>
#include <asm/init.h>
#include <asm/special_insns.h>
#include <asm/unistd.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("shimboot");
MODULE_DESCRIPTION("kexec_load as a module for the octopus 4.14 shim kernel");

/* ---- constants normally from linux/kexec.h and asm/kexec.h (gated off here) ---- */

#define KIMAGE_NO_DEST		(-1UL)
#define PAGE_COUNT(x)		(((x) + PAGE_SIZE - 1) >> PAGE_SHIFT)
#define KEXEC_SEGMENT_MAX	16

#define IND_DESTINATION		0x1
#define IND_INDIRECTION		0x2
#define IND_DONE		0x4
#define IND_SOURCE		0x8

#define KEXEC_TYPE_DEFAULT	0

#define KEXEC_ARCH_MASK		0xffff0000
#define KEXEC_ARCH_DEFAULT	(0 << 16)
#define KEXEC_ARCH_X86_64	(62 << 16)

/* x86_64 control page + trampoline layout, from arch/x86/include/asm/kexec.h */
#define PA_CONTROL_PAGE		0
#define VA_CONTROL_PAGE		1
#define PA_TABLE_PAGE		2
#define PA_SWAP_PAGE		3
#define PAGES_NR		4
#define KEXEC_CONTROL_CODE_MAX_SIZE	2048
#define KEXEC_CONTROL_PAGE_SIZE		(4096UL + 4096UL)

#define KEXEC_SOURCE_MEMORY_LIMIT	(MAXMEM - 1)
#define KEXEC_DESTINATION_MEMORY_LIMIT	(MAXMEM - 1)
#define KEXEC_CONTROL_MEMORY_LIMIT	(MAXMEM - 1)
#define KEXEC_CONTROL_MEMORY_GFP	(GFP_KERNEL | __GFP_NORETRY)

typedef unsigned long kimage_entry_t;

struct kexec_segment {
	const void __user *buf;
	size_t bufsz;
	unsigned long mem;
	size_t memsz;
};

struct kimage_arch {
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;
};

struct kimage {
	kimage_entry_t head;
	kimage_entry_t *entry;
	kimage_entry_t *last_entry;

	unsigned long start;
	struct page *control_code_page;
	struct page *swap_page;

	unsigned long nr_segments;
	struct kexec_segment segment[KEXEC_SEGMENT_MAX];

	struct list_head control_pages;
	struct list_head dest_pages;
	struct list_head unusable_pages;

	unsigned long control_page;
	unsigned int type : 1;

	struct kimage_arch arch;
};

/* non-SME identity forms of the boot-phys helpers (correct on this Intel board) */
#define page_to_boot_pfn(page)	page_to_pfn(page)
#define boot_pfn_to_page(pfn)	pfn_to_page(pfn)
#define virt_to_boot_phys(addr)	virt_to_phys(addr)
#define boot_phys_to_virt(addr)	phys_to_virt(addr)

/* ---- the relocate trampoline (relocate_kernel_64.S) ---- */
extern unsigned long kexec_control_code_size;
/* defined in asm; used both as a callable and (decayed) as the address to copy/map */
unsigned long relocate_kernel(unsigned long indirection_page,
			      unsigned long page_list,
			      unsigned long start_address,
			      unsigned int preserve_context,
			      unsigned int sme_active);

/* ---- kernel internals resolved at load time ---- */
static void (*p_machine_shutdown)(void);
static void (*p_migrate_to_reboot_cpu)(void);
static void (*p_kernel_restart_prepare)(char *cmd);
static void (*p_cpu_hotplug_enable)(void);
static int (*p_ftrace_enabled_save)(void);
static void (*p_ftrace_enabled_restore)(int);
static void (*p_hw_breakpoint_disable)(void);
static unsigned long *p_totalram_pages;
static unsigned long *p_max_pfn;
static unsigned long *p_sys_call_table;

static unsigned long totalram(void)
{
	return p_totalram_pages ? *p_totalram_pages : (1UL << 20);
}

/* ---- identity-map builder (arch/x86/mm/ident_map.c, included verbatim) ---- */
#include "ident_map.c"

/* ---- the single loaded image and the lock around loading it ---- */
static DEFINE_MUTEX(kexec_mutex);
static struct kimage *kexec_image;

/* =====================================================================
 * kexec core, trimmed to the default (non-crash, non-file) path.
 * ===================================================================== */

static struct page *kimage_alloc_page(struct kimage *image, gfp_t gfp_mask,
				      unsigned long dest);

static int sanity_check_segment_list(struct kimage *image)
{
	int i;
	unsigned long nr_segments = image->nr_segments;
	unsigned long total_pages = 0;

	for (i = 0; i < nr_segments; i++) {
		unsigned long mstart, mend;

		mstart = image->segment[i].mem;
		mend = mstart + image->segment[i].memsz;
		if (mstart > mend)
			return -EADDRNOTAVAIL;
		if ((mstart & ~PAGE_MASK) || (mend & ~PAGE_MASK))
			return -EADDRNOTAVAIL;
		if (mend >= KEXEC_DESTINATION_MEMORY_LIMIT)
			return -EADDRNOTAVAIL;
	}

	for (i = 0; i < nr_segments; i++) {
		unsigned long mstart, mend, j;

		mstart = image->segment[i].mem;
		mend = mstart + image->segment[i].memsz;
		for (j = 0; j < i; j++) {
			unsigned long pstart, pend;

			pstart = image->segment[j].mem;
			pend = pstart + image->segment[j].memsz;
			if ((mend > pstart) && (mstart < pend))
				return -EINVAL;
		}
	}

	for (i = 0; i < nr_segments; i++) {
		if (image->segment[i].bufsz > image->segment[i].memsz)
			return -EINVAL;
	}

	for (i = 0; i < nr_segments; i++) {
		if (PAGE_COUNT(image->segment[i].memsz) > totalram() / 2)
			return -EINVAL;
		total_pages += PAGE_COUNT(image->segment[i].memsz);
	}
	if (total_pages > totalram() / 2)
		return -EINVAL;

	return 0;
}

static struct kimage *do_kimage_alloc_init(void)
{
	struct kimage *image;

	image = kzalloc(sizeof(*image), GFP_KERNEL);
	if (!image)
		return NULL;

	image->head = 0;
	image->entry = &image->head;
	image->last_entry = &image->head;
	image->control_page = ~0;
	image->type = KEXEC_TYPE_DEFAULT;

	INIT_LIST_HEAD(&image->control_pages);
	INIT_LIST_HEAD(&image->dest_pages);
	INIT_LIST_HEAD(&image->unusable_pages);

	return image;
}

static int kimage_is_destination_range(struct kimage *image,
				       unsigned long start, unsigned long end)
{
	unsigned long i;

	for (i = 0; i < image->nr_segments; i++) {
		unsigned long mstart, mend;

		mstart = image->segment[i].mem;
		mend = mstart + image->segment[i].memsz;
		if ((end > mstart) && (start < mend))
			return 1;
	}
	return 0;
}

static struct page *kimage_alloc_pages(gfp_t gfp_mask, unsigned int order)
{
	struct page *pages;

	pages = alloc_pages(gfp_mask & ~__GFP_ZERO, order);
	if (pages) {
		unsigned int count, i;

		pages->mapping = NULL;
		set_page_private(pages, order);
		count = 1 << order;
		for (i = 0; i < count; i++)
			SetPageReserved(pages + i);
		if (gfp_mask & __GFP_ZERO)
			for (i = 0; i < count; i++)
				clear_highpage(pages + i);
	}
	return pages;
}

static void kimage_free_pages(struct page *page)
{
	unsigned int order, count, i;

	order = page_private(page);
	count = 1 << order;
	for (i = 0; i < count; i++)
		ClearPageReserved(page + i);
	__free_pages(page, order);
}

static void kimage_free_page_list(struct list_head *list)
{
	struct page *page, *next;

	list_for_each_entry_safe(page, next, list, lru) {
		list_del(&page->lru);
		kimage_free_pages(page);
	}
}

static struct page *kimage_alloc_normal_control_pages(struct kimage *image,
						      unsigned int order)
{
	struct list_head extra_pages;
	struct page *pages;
	unsigned int count;

	count = 1 << order;
	INIT_LIST_HEAD(&extra_pages);

	do {
		unsigned long pfn, epfn, addr, eaddr;

		pages = kimage_alloc_pages(KEXEC_CONTROL_MEMORY_GFP, order);
		if (!pages)
			break;
		pfn = page_to_boot_pfn(pages);
		epfn = pfn + count;
		addr = pfn << PAGE_SHIFT;
		eaddr = epfn << PAGE_SHIFT;
		if ((epfn >= (KEXEC_CONTROL_MEMORY_LIMIT >> PAGE_SHIFT)) ||
		    kimage_is_destination_range(image, addr, eaddr)) {
			list_add(&pages->lru, &extra_pages);
			pages = NULL;
		}
	} while (!pages);

	if (pages)
		list_add(&pages->lru, &image->control_pages);

	kimage_free_page_list(&extra_pages);
	return pages;
}

static struct page *kimage_alloc_control_pages(struct kimage *image,
					       unsigned int order)
{
	/* default type only; crash control pages are not supported here */
	return kimage_alloc_normal_control_pages(image, order);
}

static int kimage_add_entry(struct kimage *image, kimage_entry_t entry)
{
	if (*image->entry != 0)
		image->entry++;

	if (image->entry == image->last_entry) {
		kimage_entry_t *ind_page;
		struct page *page;

		page = kimage_alloc_page(image, GFP_KERNEL, KIMAGE_NO_DEST);
		if (!page)
			return -ENOMEM;

		ind_page = page_address(page);
		*image->entry = virt_to_boot_phys(ind_page) | IND_INDIRECTION;
		image->entry = ind_page;
		image->last_entry = ind_page +
			((PAGE_SIZE / sizeof(kimage_entry_t)) - 1);
	}
	*image->entry = entry;
	image->entry++;
	*image->entry = 0;
	return 0;
}

static int kimage_set_destination(struct kimage *image, unsigned long destination)
{
	destination &= PAGE_MASK;
	return kimage_add_entry(image, destination | IND_DESTINATION);
}

static int kimage_add_page(struct kimage *image, unsigned long page)
{
	page &= PAGE_MASK;
	return kimage_add_entry(image, page | IND_SOURCE);
}

static void kimage_free_extra_pages(struct kimage *image)
{
	kimage_free_page_list(&image->dest_pages);
	kimage_free_page_list(&image->unusable_pages);
}

static void kimage_terminate(struct kimage *image)
{
	if (*image->entry != 0)
		image->entry++;
	*image->entry = IND_DONE;
}

#define for_each_kimage_entry(image, ptr, entry) \
	for (ptr = &image->head; (entry = *ptr) && !(entry & IND_DONE); \
	     ptr = (entry & IND_INDIRECTION) ? \
		     boot_phys_to_virt((entry & PAGE_MASK)) : ptr + 1)

static void kimage_free_entry(kimage_entry_t entry)
{
	kimage_free_pages(boot_pfn_to_page(entry >> PAGE_SHIFT));
}

static void machine_kexec_cleanup(struct kimage *image);

static void kimage_free(struct kimage *image)
{
	kimage_entry_t *ptr, entry;
	kimage_entry_t ind = 0;

	if (!image)
		return;

	kimage_free_extra_pages(image);
	for_each_kimage_entry(image, ptr, entry) {
		if (entry & IND_INDIRECTION) {
			if (ind & IND_INDIRECTION)
				kimage_free_entry(ind);
			ind = entry;
		} else if (entry & IND_SOURCE) {
			kimage_free_entry(entry);
		}
	}
	if (ind & IND_INDIRECTION)
		kimage_free_entry(ind);

	machine_kexec_cleanup(image);
	kimage_free_page_list(&image->control_pages);
	kfree(image);
}

static kimage_entry_t *kimage_dst_used(struct kimage *image, unsigned long page)
{
	kimage_entry_t *ptr, entry;
	unsigned long destination = 0;

	for_each_kimage_entry(image, ptr, entry) {
		if (entry & IND_DESTINATION)
			destination = entry & PAGE_MASK;
		else if (entry & IND_SOURCE) {
			if (page == destination)
				return ptr;
			destination += PAGE_SIZE;
		}
	}
	return NULL;
}

static struct page *kimage_alloc_page(struct kimage *image, gfp_t gfp_mask,
				      unsigned long destination)
{
	struct page *page;
	unsigned long addr;

	list_for_each_entry(page, &image->dest_pages, lru) {
		addr = page_to_boot_pfn(page) << PAGE_SHIFT;
		if (addr == destination) {
			list_del(&page->lru);
			return page;
		}
	}
	page = NULL;
	while (1) {
		kimage_entry_t *old;

		page = kimage_alloc_pages(gfp_mask, 0);
		if (!page)
			return NULL;
		if (page_to_boot_pfn(page) >
		    (KEXEC_SOURCE_MEMORY_LIMIT >> PAGE_SHIFT)) {
			list_add(&page->lru, &image->unusable_pages);
			continue;
		}
		addr = page_to_boot_pfn(page) << PAGE_SHIFT;

		if (addr == destination)
			break;
		if (!kimage_is_destination_range(image, addr, addr + PAGE_SIZE))
			break;

		old = kimage_dst_used(image, addr);
		if (old) {
			unsigned long old_addr;
			struct page *old_page;

			old_addr = *old & PAGE_MASK;
			old_page = boot_pfn_to_page(old_addr >> PAGE_SHIFT);
			copy_highpage(page, old_page);
			*old = addr | (*old & ~PAGE_MASK);

			if (!(gfp_mask & __GFP_HIGHMEM) && PageHighMem(old_page)) {
				kimage_free_pages(old_page);
				continue;
			}
			addr = old_addr;
			page = old_page;
			break;
		}
		list_add(&page->lru, &image->dest_pages);
	}
	return page;
}

static int kimage_load_segment(struct kimage *image, struct kexec_segment *segment)
{
	unsigned long maddr;
	size_t ubytes, mbytes;
	int result;
	const unsigned char __user *buf = segment->buf;

	result = 0;
	ubytes = segment->bufsz;
	mbytes = segment->memsz;
	maddr = segment->mem;

	result = kimage_set_destination(image, maddr);
	if (result < 0)
		goto out;

	while (mbytes) {
		struct page *page;
		char *ptr;
		size_t uchunk, mchunk;

		page = kimage_alloc_page(image, GFP_HIGHUSER, maddr);
		if (!page) {
			result = -ENOMEM;
			goto out;
		}
		result = kimage_add_page(image, page_to_boot_pfn(page) << PAGE_SHIFT);
		if (result < 0)
			goto out;

		ptr = kmap(page);
		clear_page(ptr);
		ptr += maddr & ~PAGE_MASK;
		mchunk = min_t(size_t, mbytes, PAGE_SIZE - (maddr & ~PAGE_MASK));
		uchunk = min(ubytes, mchunk);

		result = copy_from_user(ptr, buf, uchunk);
		kunmap(page);
		if (result) {
			result = -EFAULT;
			goto out;
		}
		ubytes -= uchunk;
		maddr += mchunk;
		buf += mchunk;
		mbytes -= mchunk;
	}
out:
	return result;
}

/* =====================================================================
 * arch/x86 machine_kexec, trimmed (no purgatory, no crash, no jump).
 * ===================================================================== */

static void free_transition_pgtable(struct kimage *image)
{
	free_page((unsigned long)image->arch.p4d);
	image->arch.p4d = NULL;
	free_page((unsigned long)image->arch.pud);
	image->arch.pud = NULL;
	free_page((unsigned long)image->arch.pmd);
	image->arch.pmd = NULL;
	free_page((unsigned long)image->arch.pte);
	image->arch.pte = NULL;
}

static int init_transition_pgtable(struct kimage *image, pgd_t *pgd)
{
	p4d_t *p4d;
	pud_t *pud;
	pmd_t *pmd;
	pte_t *pte;
	unsigned long vaddr, paddr;
	int result = -ENOMEM;

	vaddr = (unsigned long)relocate_kernel;
	paddr = __pa(page_address(image->control_code_page) + PAGE_SIZE);
	pgd += pgd_index(vaddr);
	if (!pgd_present(*pgd)) {
		p4d = (p4d_t *)get_zeroed_page(GFP_KERNEL);
		if (!p4d)
			goto err;
		image->arch.p4d = p4d;
		set_pgd(pgd, __pgd(__pa(p4d) | _KERNPG_TABLE));
	}
	p4d = p4d_offset(pgd, vaddr);
	if (!p4d_present(*p4d)) {
		pud = (pud_t *)get_zeroed_page(GFP_KERNEL);
		if (!pud)
			goto err;
		image->arch.pud = pud;
		set_p4d(p4d, __p4d(__pa(pud) | _KERNPG_TABLE));
	}
	pud = pud_offset(p4d, vaddr);
	if (!pud_present(*pud)) {
		pmd = (pmd_t *)get_zeroed_page(GFP_KERNEL);
		if (!pmd)
			goto err;
		image->arch.pmd = pmd;
		set_pud(pud, __pud(__pa(pmd) | _KERNPG_TABLE));
	}
	pmd = pmd_offset(pud, vaddr);
	if (!pmd_present(*pmd)) {
		pte = (pte_t *)get_zeroed_page(GFP_KERNEL);
		if (!pte)
			goto err;
		image->arch.pte = pte;
		set_pmd(pmd, __pmd(__pa(pte) | _KERNPG_TABLE));
	}
	pte = pte_offset_kernel(pmd, vaddr);
	set_pte(pte, pfn_pte(paddr >> PAGE_SHIFT, PAGE_KERNEL_EXEC_NOENC));
	return 0;
err:
	return result;
}

static void *alloc_pgt_page(void *data)
{
	struct kimage *image = (struct kimage *)data;
	struct page *page;
	void *p = NULL;

	page = kimage_alloc_control_pages(image, 0);
	if (page) {
		p = page_address(page);
		clear_page(p);
	}
	return p;
}

static int init_pgtable(struct kimage *image, unsigned long start_pgtable)
{
	struct x86_mapping_info info = {
		.alloc_pgt_page = alloc_pgt_page,
		.context = image,
		.page_flag = __PAGE_KERNEL_LARGE_EXEC,
		.kernpg_flag = _KERNPG_TABLE_NOENC,
		.direct_gbpages = false,
	};
	unsigned long mstart, mend;
	pgd_t *level4p;
	int result;
	int i;

	level4p = (pgd_t *)__va(start_pgtable);
	clear_page(level4p);

	/*
	 * Identity-map all of low RAM in one range. The in-tree code walks
	 * pfn_mapped[] to skip holes; mapping [0, max_pfn) is a harmless
	 * superset for the brief trampoline and avoids a static symbol.
	 */
	mstart = 0;
	mend = (p_max_pfn ? *p_max_pfn : (MAXMEM >> PAGE_SHIFT)) << PAGE_SHIFT;
	result = kernel_ident_mapping_init(&info, level4p, mstart, mend);
	if (result)
		return result;

	/* plus each destination segment, in case it lies above max_pfn */
	for (i = 0; i < image->nr_segments; i++) {
		mstart = image->segment[i].mem;
		mend = mstart + image->segment[i].memsz;
		result = kernel_ident_mapping_init(&info, level4p, mstart, mend);
		if (result)
			return result;
	}

	return init_transition_pgtable(image, level4p);
}

static void set_idt(void *newidt, u16 limit)
{
	struct desc_ptr curidt;

	curidt.size = limit;
	curidt.address = (unsigned long)newidt;
	__asm__ __volatile__("lidtq %0\n" : : "m"(curidt));
}

static void set_gdt(void *newgdt, u16 limit)
{
	struct desc_ptr curgdt;

	curgdt.size = limit;
	curgdt.address = (unsigned long)newgdt;
	__asm__ __volatile__("lgdtq %0\n" : : "m"(curgdt));
}

static void load_segments(void)
{
	__asm__ __volatile__(
		"\tmovl %0,%%ds\n"
		"\tmovl %0,%%es\n"
		"\tmovl %0,%%ss\n"
		"\tmovl %0,%%fs\n"
		"\tmovl %0,%%gs\n"
		: : "a"(__KERNEL_DS) : "memory");
}

static int machine_kexec_prepare(struct kimage *image)
{
	unsigned long start_pgtable;

	start_pgtable = page_to_pfn(image->control_code_page) << PAGE_SHIFT;
	return init_pgtable(image, start_pgtable);
}

static void machine_kexec_cleanup(struct kimage *image)
{
	free_transition_pgtable(image);
}

/*
 * Past the point of no return: move the new kernel into place and jump.
 * Must not allocate or fail.
 */
static void machine_kexec(struct kimage *image)
{
	unsigned long page_list[PAGES_NR];
	void *control_page;
	int save_ftrace_enabled = 0;

	if (p_ftrace_enabled_save)
		save_ftrace_enabled = p_ftrace_enabled_save();

	local_irq_disable();
	if (p_hw_breakpoint_disable)
		p_hw_breakpoint_disable();

	control_page = page_address(image->control_code_page) + PAGE_SIZE;
	memcpy(control_page, relocate_kernel, KEXEC_CONTROL_CODE_MAX_SIZE);

	page_list[PA_CONTROL_PAGE] = virt_to_phys(control_page);
	page_list[VA_CONTROL_PAGE] = (unsigned long)control_page;
	page_list[PA_TABLE_PAGE] =
		(unsigned long)__pa(page_address(image->control_code_page));

	page_list[PA_SWAP_PAGE] = page_to_pfn(image->swap_page) << PAGE_SHIFT;

	/*
	 * Force-load the segment registers, then zap the gdt and idt: the new
	 * kernel sets up its own. See the in-tree comment for why this works.
	 */
	load_segments();
	set_gdt(phys_to_virt(0), 0);
	set_idt(phys_to_virt(0), 0);

	image->start = relocate_kernel((unsigned long)image->head,
				       (unsigned long)page_list,
				       image->start, 0, 0);

	/* only reached if relocate_kernel returns (it should not) */
	if (p_ftrace_enabled_restore)
		p_ftrace_enabled_restore(save_ftrace_enabled);
}

/* =====================================================================
 * load path and the syscall hooks
 * ===================================================================== */

static int do_kexec_load(unsigned long entry, unsigned long nr_segments,
			 struct kexec_segment __user *segments, unsigned long flags)
{
	struct kimage *image, *old;
	unsigned long i;
	int ret;

	if (nr_segments == 0) {
		kimage_free(xchg(&kexec_image, NULL));
		return 0;
	}

	image = do_kimage_alloc_init();
	if (!image)
		return -ENOMEM;
	image->start = entry;

	image->nr_segments = nr_segments;
	if (copy_from_user(image->segment, segments,
			   nr_segments * sizeof(*segments))) {
		ret = -EFAULT;
		goto out_free;
	}

	ret = sanity_check_segment_list(image);
	if (ret)
		goto out_free;

	ret = -ENOMEM;
	image->control_code_page =
		kimage_alloc_control_pages(image, get_order(KEXEC_CONTROL_PAGE_SIZE));
	if (!image->control_code_page) {
		pr_err("could not allocate control_code_buffer\n");
		goto out_free;
	}
	image->swap_page = kimage_alloc_control_pages(image, 0);
	if (!image->swap_page) {
		pr_err("could not allocate swap buffer\n");
		goto out_free;
	}

	ret = machine_kexec_prepare(image);
	if (ret)
		goto out_free;

	for (i = 0; i < nr_segments; i++) {
		ret = kimage_load_segment(image, &image->segment[i]);
		if (ret)
			goto out_free;
	}

	kimage_terminate(image);

	old = xchg(&kexec_image, image);
	kimage_free(old);
	return 0;

out_free:
	kimage_free(image);
	return ret;
}

/* classic x86_64 syscall signature (4.14 has no pt_regs stubs) */
static asmlinkage long (*orig_kexec_load)(unsigned long, unsigned long,
					  unsigned long, unsigned long);
static asmlinkage long (*orig_reboot)(unsigned long, unsigned long,
				      unsigned long, unsigned long);

static asmlinkage long my_kexec_load(unsigned long entry,
				     unsigned long nr_segments,
				     unsigned long segments_arg,
				     unsigned long flags)
{
	struct kexec_segment __user *segments =
		(struct kexec_segment __user *)segments_arg;
	int result;

	if (!capable(CAP_SYS_BOOT))
		return -EPERM;
	/* we only support a plain default-type load */
	if (flags & ~KEXEC_ARCH_MASK)
		return -EINVAL;
	if (((flags & KEXEC_ARCH_MASK) != KEXEC_ARCH_X86_64) &&
	    ((flags & KEXEC_ARCH_MASK) != KEXEC_ARCH_DEFAULT))
		return -EINVAL;
	if (nr_segments > KEXEC_SEGMENT_MAX)
		return -EINVAL;

	if (!mutex_trylock(&kexec_mutex))
		return -EBUSY;
	result = do_kexec_load(entry, nr_segments, segments, flags);
	mutex_unlock(&kexec_mutex);
	return result;
}

static int kexec_now(void)
{
	int error = 0;

	if (!mutex_trylock(&kexec_mutex))
		return -EBUSY;
	if (!kexec_image) {
		error = -EINVAL;
		goto unlock;
	}

	p_kernel_restart_prepare(NULL);
	p_migrate_to_reboot_cpu();
	/* migrate_to_reboot_cpu disabled hotplug; the jump path needs it back */
	if (p_cpu_hotplug_enable)
		p_cpu_hotplug_enable();
	pr_emerg("starting new kernel\n");
	p_machine_shutdown();

	machine_kexec(kexec_image);
	/* not reached on success */
unlock:
	mutex_unlock(&kexec_mutex);
	return error;
}

static asmlinkage long my_reboot(unsigned long magic1, unsigned long magic2,
				 unsigned long cmd, unsigned long arg)
{
	if (magic1 == LINUX_REBOOT_MAGIC1 &&
	    (magic2 == LINUX_REBOOT_MAGIC2 || magic2 == LINUX_REBOOT_MAGIC2A ||
	     magic2 == LINUX_REBOOT_MAGIC2B || magic2 == LINUX_REBOOT_MAGIC2C) &&
	    cmd == LINUX_REBOOT_CMD_KEXEC) {
		if (!capable(CAP_SYS_BOOT))
			return -EPERM;
		return kexec_now();
	}
	return orig_reboot(magic1, magic2, cmd, arg);
}

/* ---- sys_call_table patching ---- */

static unsigned long cr0_wp_disable(void)
{
	unsigned long cr0 = read_cr0();

	write_cr0(cr0 & ~X86_CR0_WP);
	return cr0;
}

static void cr0_restore(unsigned long cr0)
{
	write_cr0(cr0);
}

#define RESOLVE(var, name) do {                                          \
		(var) = (void *)kallsyms_lookup_name(name);              \
		if (!(var))                                              \
			pr_warn("could not resolve %s\n", name);         \
	} while (0)

#define RESOLVE_REQUIRED(var, name) do {                                 \
		(var) = (void *)kallsyms_lookup_name(name);              \
		if (!(var)) {                                            \
			pr_err("missing required symbol %s\n", name);    \
			return -ENOENT;                                  \
		}                                                        \
	} while (0)

static int __init shimboot_kexec_init(void)
{
	unsigned long cr0;

	BUILD_BUG_ON(sizeof(struct kexec_segment) != 32);

	RESOLVE_REQUIRED(p_sys_call_table, "sys_call_table");
	RESOLVE_REQUIRED(p_machine_shutdown, "machine_shutdown");
	RESOLVE_REQUIRED(p_migrate_to_reboot_cpu, "migrate_to_reboot_cpu");
	RESOLVE_REQUIRED(p_kernel_restart_prepare, "kernel_restart_prepare");
	RESOLVE_REQUIRED(p_max_pfn, "max_pfn");
	/* optional: the load still works without these, kexec is just noisier */
	RESOLVE(p_cpu_hotplug_enable, "cpu_hotplug_enable");
	RESOLVE(p_totalram_pages, "totalram_pages");
	RESOLVE(p_ftrace_enabled_save, "__ftrace_enabled_save");
	RESOLVE(p_ftrace_enabled_restore, "__ftrace_enabled_restore");
	RESOLVE(p_hw_breakpoint_disable, "hw_breakpoint_disable");

	if (kexec_control_code_size > KEXEC_CONTROL_CODE_MAX_SIZE) {
		pr_err("relocate trampoline too big (%lu > %d)\n",
		       kexec_control_code_size, KEXEC_CONTROL_CODE_MAX_SIZE);
		return -EINVAL;
	}

	orig_kexec_load = (void *)p_sys_call_table[__NR_kexec_load];
	orig_reboot = (void *)p_sys_call_table[__NR_reboot];

	preempt_disable();
	cr0 = cr0_wp_disable();
	p_sys_call_table[__NR_kexec_load] = (unsigned long)my_kexec_load;
	p_sys_call_table[__NR_reboot] = (unsigned long)my_reboot;
	cr0_restore(cr0);
	preempt_enable();

	pr_info("ready: kexec_load and reboot(LINUX_REBOOT_CMD_KEXEC) are now served (trampoline %lu bytes)\n",
		kexec_control_code_size);
	return 0;
}

static void __exit shimboot_kexec_exit(void)
{
	unsigned long cr0;

	preempt_disable();
	cr0 = cr0_wp_disable();
	if (orig_kexec_load)
		p_sys_call_table[__NR_kexec_load] = (unsigned long)orig_kexec_load;
	if (orig_reboot)
		p_sys_call_table[__NR_reboot] = (unsigned long)orig_reboot;
	cr0_restore(cr0);
	preempt_enable();

	mutex_lock(&kexec_mutex);
	kimage_free(xchg(&kexec_image, NULL));
	mutex_unlock(&kexec_mutex);

	pr_info("unloaded\n");
}

module_init(shimboot_kexec_init);
module_exit(shimboot_kexec_exit);
