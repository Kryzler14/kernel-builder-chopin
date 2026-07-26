#!/bin/bash
# Apply SusFS integration to KSU-Next v3.2.0 kernel module
# Usage: integrate.sh <KSU_kernel_dir>
set -e

KSU_DIR="$1"
if [ -z "$KSU_DIR" ]; then
    echo "Usage: $0 <KSU-kernel-dir>"
    exit 1
fi

echo "=== SusFS KSU integration for v3.2.0 ==="

# 1. core/init.c: add include + susfs_init call
echo "[1/6] core/init.c"
sed -i '/^#include "ksu.h"/a #include <linux/susfs.h>' "$KSU_DIR/core/init.c"
sed -i '/ksu_syscall_hook_init();/a\\t#ifdef CONFIG_KSU_SUSFS\n\tsusfs_init();\n\t#endif' "$KSU_DIR/core/init.c"

# 2. selinux/selinux.c: add wrapper functions
echo "[2/6] selinux/selinux.c"
cat >> "$KSU_DIR/selinux/selinux.c" << 'SELINUX_EOF'

/* SusFS compatibility wrappers */
#ifdef CONFIG_KSU_SUSFS
bool susfs_is_current_ksu_domain(void)
{
	return is_ksu_domain();
}

bool susfs_is_current_zygote_domain(void)
{
	return is_zygote(current_cred());
}

bool susfs_is_current_init_domain(void)
{
	return is_init(current_cred());
}
#endif
SELINUX_EOF

# 3. selinux/selinux.h: add declarations
echo "[3/6] selinux/selinux.h"
sed -i '/^bool is_init/a #ifdef CONFIG_KSU_SUSFS\nbool susfs_is_current_ksu_domain(void);\nbool susfs_is_current_zygote_domain(void);\nbool susfs_is_current_init_domain(void);\n#endif' "$KSU_DIR/selinux/selinux.h"

# 4. selinux/rules.c: add include
echo "[4/6] selinux/rules.c"
sed -i '/^#include "selinux.h"/a #include <linux/susfs.h>' "$KSU_DIR/selinux/rules.c"

# 5. feature/kernel_umount.c: add functions
echo "[5/6] feature/kernel_umount.c"
sed -i '/^#include <linux\/types.h>/a #include <linux/susfs.h>' "$KSU_DIR/feature/kernel_umount.c"
# Rename try_umount and add params
sed -i 's/^static void try_umount(const char \*mnt, int flags)/void ksu_try_umount(const char *mnt, bool check_mnt, int flags, uid_t uid)/' "$KSU_DIR/feature/kernel_umount.c"
# Add unused param suppression after opening brace
sed -i '/^void ksu_try_umount/,/^}$/{
    /^}$/i\\t(void)check_mnt;\n\t(void)uid;
}' "$KSU_DIR/feature/kernel_umount.c"
# Add susfs_try_umount_all function before struct umount_tw
LINE=$(grep -n "^struct umount_tw" "$KSU_DIR/feature/kernel_umount.c" | cut -d: -f1)
sed -i "${LINE}i\\\n#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT\nvoid susfs_try_umount_all(uid_t uid)\n{\n\tsusfs_try_umount(uid);\n\tksu_try_umount(\"/system\", false, 0, uid);\n\tksu_try_umount(\"/system_ext\", false, 0, uid);\n\tksu_try_umount(\"/vendor\", false, 0, uid);\n\tksu_try_umount(\"/product\", false, 0, uid);\n\tksu_try_umount(\"/odm\", false, 0, uid);\n\tksu_try_umount(\"/data/adb/modules\", false, MNT_DETACH, uid);\n\tksu_try_umount(\"/debug_ramdisk\", false, MNT_DETACH, uid);\n\tksu_try_umount(\"/sbin\", false, MNT_DETACH, uid);\n}\n#endif\n" "$KSU_DIR/feature/kernel_umount.c"
# Update call site
sed -i 's/\t\ttry_umount(entry->umountable, entry->flags);/\t\tksu_try_umount(entry->umountable, false, entry->flags, 0);/' "$KSU_DIR/feature/kernel_umount.c"

echo "=== Integration done ==="
