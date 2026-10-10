//smoke test: proves a module built here matches the shim kernel's vermagic and loads.
//on the device: insmod hello.ko && dmesg | tail -n2
#include <linux/module.h>
#include <linux/kallsyms.h>

static int __init hello_init(void)
{
	pr_info("shimboot hello: loaded, kallsyms_lookup_name(\"machine_restart\") = %px\n",
		(void *)kallsyms_lookup_name("machine_restart"));
	return 0;
}

static void __exit hello_exit(void)
{
	pr_info("shimboot hello: unloaded\n");
}

module_init(hello_init);
module_exit(hello_exit);
MODULE_LICENSE("GPL");
