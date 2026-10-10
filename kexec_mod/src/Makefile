obj-m := shimboot_kexec.o
shimboot_kexec-y := main.o relocate_kernel_64.o
# ident_map.c is #included by main.c, so it is not a separate object

# the relocate trampoline is hand-written position-independent reboot code; keep objtool
# off it, exactly as arch/x86/kernel/Makefile does for the in-tree copy
OBJECT_FILES_NON_STANDARD_relocate_kernel_64.o := y
