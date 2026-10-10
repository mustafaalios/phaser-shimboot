// SPDX-License-Identifier: GPL-2.0
//smoke test: proves a module built here matches the shim kernel's vermagic and loads,
//and reports whether every kernel symbol the real kexec module needs resolves on THIS kernel.
//on the device: insmod hello.ko; dmesg | tail -n 20; rmmod hello
#include <linux/module.h>
#include <linux/kallsyms.h>

static const char * const required[] = {
	"sys_call_table", "machine_shutdown", "migrate_to_reboot_cpu",
	"kernel_restart_prepare", "max_pfn",
};
static const char * const optional[] = {
	"cpu_hotplug_enable", "totalram_pages",
	"__ftrace_enabled_save", "__ftrace_enabled_restore", "hw_breakpoint_disable",
};

static int __init hello_init(void)
{
	int i, missing = 0;
	unsigned long a;

	pr_info("shimboot smoke: loaded ok (vermagic matched)\n");
	for (i = 0; i < ARRAY_SIZE(required); i++) {
		a = kallsyms_lookup_name(required[i]);
		pr_info("  required %-24s %s\n", required[i], a ? "resolved" : "MISSING");
		if (!a)
			missing++;
	}
	for (i = 0; i < ARRAY_SIZE(optional); i++) {
		a = kallsyms_lookup_name(optional[i]);
		pr_info("  optional %-24s %s\n", optional[i], a ? "resolved" : "absent");
	}
	if (missing)
		pr_warn("shimboot smoke: %d REQUIRED symbol(s) missing - the kexec module cannot work as-is\n",
			missing);
	else
		pr_info("shimboot smoke: all required symbols present - the kexec module should be able to load\n");
	return 0;
}

static void __exit hello_exit(void)
{
	pr_info("shimboot smoke: unloaded\n");
}

module_init(hello_init);
module_exit(hello_exit);
MODULE_LICENSE("GPL");
