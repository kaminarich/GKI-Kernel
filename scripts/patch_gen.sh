#!/bin/bash

# Bikin direktori patches
mkdir -p patches/ksu
mkdir -p patches/susfs
mkdir -p patches/hooks

echo "Generating patches..."

# ==============================================================================
# 1. KSU Manager Support
# ==============================================================================
cat << 'EOF' > patches/ksu/managers.patch
diff --git a/kernel/Kbuild b/kernel/Kbuild
index abd1380..6274d22 100644
--- a/kernel/Kbuild
+++ b/kernel/Kbuild
@@ -64,6 +64,11 @@ $(info -- $(REPO_NAME) version name: $(KSU_VERSION_FULL))
 
 ccflags-y += -DKSU_VERSION=$(KSU_VERSION)
 ccflags-y += -DKSU_VERSION_FULL=\"$(KSU_VERSION_FULL)\"
+
+ifndef RESUKISU_MANAGER_LIST
+RESUKISU_MANAGER_LIST := 0x377:d3469712b6214462764a1d8d3e5cbe1d6819a0b629791b9f4101867821f1df64,0x35c:947ae944f3de4ed4c21a7e4f7953ecf351bfa2b36239da37a34111ad29993eef,0x375:484fcba6e6c43b1fb09700633bf2fb4758f13cb0b2f4457b80d075084b26c588,0x384:a9462b8b98ea1ca7901b0cbdcebfaa35f0aa95e51b01d66e6b6d2c81b97746d8,0x396:f415f4ed9435427e1fdf7f1fccd4dbc07b3d6b8751e4dbcec6f19671f427870b,0x381:52d52d8c8bfbe53dc2b6ff1c613184e2c03013e090fe8905d8e3d5dc2658c2e4,0x3e6:79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7,0x338:f26471a28031130362bce7eebffb9a0b8afc3095f163ce0c75a309f03b644a1f
+endif
+
+ccflags-y += -DKSU_NEXT_MANAGER_LIST=\"$(RESUKISU_MANAGER_LIST)\"

diff --git a/kernel/su/manager_sign.h b/kernel/su/manager_sign.h
index 0000000..1111111 100644
--- a/kernel/su/manager_sign.h
+++ b/kernel/su/manager_sign.h
@@ -30,6 +30,46 @@
 #define EXPECTED_HASH_RSUNTK                                                   \
     "f415f4ed9435427e1fdf7f1fccd4dbc07b3d6b8751e4dbcec6f19671f427870b"
 
+// KOWX712/KernelSU (0x375)
+#define EXPECTED_SIZE_KOWX712 0x375
+#define EXPECTED_HASH_KOWX712                                                     \
+    "484fcba6e6c43b1fb09700633bf2fb4758f13cb0b2f4457b80d075084b26c588"
+
+// MAMBO/KernelSU (0x384)
+#define EXPECTED_SIZE_MAMBO 0x384
+#define EXPECTED_HASH_MAMBO                                                      \
+    "a9462b8b98ea1ca7901b0cbdcebfaa35f0aa95e51b01d66e6b6d2c81b97746d8"
+
+// Manager WILD KSU (0x381)
+#define EXPECTED_SIZE_WILD 0x381
+#define EXPECTED_HASH_WILD                                                      \
+    "52d52d8c8bfbe53dc2b6ff1c613184e2c03013e090fe8905d8e3d5dc2658c2e4"
+
+// Manager KernelSU-Next (0x3e6)
+#define EXPECTED_SIZE_NEXT 0x3e6
+#define EXPECTED_HASH_NEXT                                                      \
+    "79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7"
+
+// Manager KernelSU-pershoot/KernelSU-pershoot (0x338)
+#define EXPECTED_SIZE_pershoot 0x338
+#define EXPECTED_HASH_pershoot                                                    \
+    "f26471a28031130362bce7eebffb9a0b8afc3095f163ce0c75a309f03b644a1f"
+
 // Neko/KernelSU
 #define EXPECTED_SIZE_NEKO 0x29c
 #define EXPECTED_HASH_NEKO                                                     \
diff --git a/kernel/su/apk_sign.c b/kernel/su/apk_sign.c
index 0000000..2222222 100644
--- a/kernel/su/apk_sign.c
+++ b/kernel/su/apk_sign.c
@@ -18,6 +18,15 @@ static apk_sign_key_t apk_sign_keys[] = {
     { EXPECTED_SIZE_RESUKISU, EXPECTED_HASH_RESUKISU }, /* ReSukiSU/ReSukiSU */
+    { EXPECTED_SIZE_KOWX712, EXPECTED_HASH_KOWX712 }, // KOWX712
+    { EXPECTED_SIZE_MAMBO, EXPECTED_HASH_MAMBO }, // MAMBO
+    { EXPECTED_SIZE_WILD, EXPECTED_HASH_WILD }, // WILD
+    { EXPECTED_SIZE_NEXT, EXPECTED_HASH_NEXT }, // NEXT
+    { EXPECTED_SIZE_pershoot, EXPECTED_HASH_pershoot }, // pershoot
 #ifdef CONFIG_KSU_MULTI_MANAGER_SUPPORT
     { EXPECTED_SIZE_WEISHU, EXPECTED_HASH_WEISHU }, // Official
     { EXPECTED_SIZE_5EC1CFF,  EXPECTED_HASH_5EC1CFF }, // 5ec1cff/KernelSU
EOF

# ==============================================================================
# 2. SuSFS Fixes (FIXED HEADERS)
# ==============================================================================
cat << 'EOF' > patches/susfs/fixes.patch
diff --git a/fs/statfs.c b/fs/statfs.c
index 056b171a848e..8a15f6659caf 100644
--- a/fs/statfs.c
+++ b/fs/statfs.c
@@ -10,9 +10,11 @@
 #include <linux/uaccess.h>
 #include <linux/compat.h>
 #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+#ifndef __GENKSYMS__
 #include <linux/susfs_def.h>
 #include "mount.h"
 #endif
+#endif
 #include "internal.h"
 
 static int flags_by_mnt(int mnt_flags)
diff --git a/fs/proc/base.c b/fs/proc/base.c
index 02c9a5e3f959..516ef10bbeb8 100644
--- a/fs/proc/base.c
+++ b/fs/proc/base.c
@@ -99,6 +99,9 @@
 #include <linux/resctrl.h>
 #include <linux/cn_proc.h>
 #include <linux/cpufreq_times.h>
+#ifdef CONFIG_KSU_SUSFS_SUS_MAP
+#include <linux/susfs_def.h>
+#endif
 #include <linux/dma-buf.h>
 #include <trace/events/oom.h>
 #include <trace/hooks/sched.h>
diff --git a/fs/namespace.c b/fs/namespace.c
index 8970a57abe10..012bd401cbc7 100644
--- a/fs/namespace.c
+++ b/fs/namespace.c
@@ -32,10 +32,35 @@
 #include <linux/fs_context.h>
 #include <linux/shmem_fs.h>
 #include <linux/mnt_idmapping.h>
+#if defined(CONFIG_KSU_SUSFS_SUS_MOUNT) || defined(CONFIG_KSU_SUSFS_TRY_UMOUNT)
+#include <linux/susfs_def.h>
+#endif
 
 #include "pnode.h"
 #include "internal.h"
 #include <trace/hooks/blk.h>
 
+#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+extern bool susfs_is_current_ksu_domain(void);
+extern bool susfs_is_current_zygote_domain(void);
+extern bool susfs_is_boot_completed_triggered;
+
+static DEFINE_IDA(susfs_ksu_mnt_group_ida);
+
+#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
+#endif
+
+#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
+extern void susfs_auto_add_sus_ksu_default_mount(const char __user *to_pathname);
+bool susfs_is_auto_add_sus_ksu_default_mount_enabled = true;
+#endif
+#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
+extern void susfs_auto_add_sus_bind_mount(const char *pathname, struct path *path_target);
+bool susfs_is_auto_add_sus_bind_mount_enabled = true;
+#endif
+#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
+extern void susfs_auto_add_try_umount_for_bind_mount(struct path *path);
+bool susfs_is_auto_add_try_umount_for_bind_mount_enabled = true;
+#endif
+
 /* Maximum number of mounts in a mount namespace */
 static unsigned int sysctl_mount_max __read_mostly = 100000;
diff --git a/fs/proc/task_mmu.c b/fs/proc/task_mmu.c
index bf966767d3fb..c91bfbda7755 100644
--- a/fs/proc/task_mmu.c
+++ b/fs/proc/task_mmu.c
@@ -1763,6 +1763,9 @@ static ssize_t pagemap_read(struct file *file, char __user *buf,
 	unsigned long start_vaddr;
 	unsigned long end_vaddr;
 	int ret = 0, copied = 0;
+#ifdef CONFIG_KSU_SUSFS_SUS_MAP
+       struct vm_area_struct *vma;
+#endif
 
 	if (!mm || !mmget_not_zero(mm))
 		goto out;
EOF

# ==============================================================================
# 3. Manual Hooks
# ==============================================================================
cat << 'EOF' > patches/hooks/manual_hook.patch
diff --git a/drivers/input/input.c b/drivers/input/input.c
index 8c5fdb0f858a..605a2b33e46d 100644
--- a/drivers/input/input.c
+++ b/drivers/input/input.c
@@ -424,11 +424,21 @@ void input_handle_event(struct input_dev *dev,
  * to 'seed' initial state of a switch or initial position of absolute
  * axis, etc.
  */
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+extern bool ksu_input_hook __read_mostly;
+extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
+#endif
+
 void input_event(struct input_dev *dev,
 		 unsigned int type, unsigned int code, int value)
 {
 	unsigned long flags;
 
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+	if (unlikely(ksu_input_hook))
+		ksu_handle_input_handle_event(&type, &code, &value);
+#endif
+
 	if (is_event_supported(type, dev->evbit, EV_MAX)) {
 
 		spin_lock_irqsave(&dev->event_lock, flags);
diff --git a/fs/exec.c b/fs/exec.c
index 28a3f560dae3..44931cb303dc 100644
--- a/fs/exec.c
+++ b/fs/exec.c
@@ -2114,11 +2114,26 @@ void set_dumpable(struct mm_struct *mm, int value)
 	set_mask_bits(&mm->flags, MMF_DUMPABLE_MASK, value);
 }
 
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+extern bool ksu_execveat_hook __read_mostly;
+extern __attribute__((hot, always_inline)) int ksu_handle_execve_sucompat(int *fd, const char __user **filename_user,
+			       void *__never_use_argv, void *__never_use_envp,
+			       int *__never_use_flags);
+extern int ksu_handle_execve_ksud(const char __user *filename_user,
+			const char __user *const __user *__argv);
+#endif
+
 SYSCALL_DEFINE3(execve,
 		const char __user *, filename,
 		const char __user *const __user *, argv,
 		const char __user *const __user *, envp)
 {
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+	if (unlikely(ksu_execveat_hook))
+		ksu_handle_execve_ksud(filename, argv);
+	else
+		ksu_handle_execve_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);
+#endif
 	return do_execve(getname(filename), argv, envp);
 }
 
@@ -2138,6 +2153,10 @@ COMPAT_SYSCALL_DEFINE3(execve, const char __user *, filename,
 	const compat_uptr_t __user *, argv,
 	const compat_uptr_t __user *, envp)
 {
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK) // 32-bit su and 32-on-64 support
+	if (!ksu_execveat_hook)
+		ksu_handle_execve_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);
+#endif
 	return compat_do_execve(getname(filename), argv, envp);
 }
 
diff --git a/fs/open.c b/fs/open.c
index 89aa63c0607b..11cd3bd35d34 100644
--- a/fs/open.c
+++ b/fs/open.c
@@ -527,8 +527,16 @@ static long do_faccessat(int dfd, const char __user *filename, int mode, int fla
 	return res;
 }
 
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+extern __attribute__((hot, always_inline)) int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
+			                    int *flags);
+#endif
+
 SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
 {
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
+#endif
 	return do_faccessat(dfd, filename, mode, 0);
 }
 
diff --git a/fs/read_write.c b/fs/read_write.c
index d09df87367c5..837fcce88a89 100644
--- a/fs/read_write.c
+++ b/fs/read_write.c
@@ -618,8 +618,18 @@ ssize_t ksys_read(unsigned int fd, char __user *buf, size_t count)
 	return ret;
 }
 
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+extern bool ksu_vfs_read_hook __read_mostly;
+extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,
+			size_t *count_ptr);
+#endif
+
 SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
 {
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+	if (unlikely(ksu_vfs_read_hook)) 
+		ksu_handle_sys_read(fd, &buf, &count);
+#endif
 	return ksys_read(fd, buf, count);
 }
 
diff --git a/fs/stat.c b/fs/stat.c
index 517fa4ed885e..8676c7cbc3ec 100644
--- a/fs/stat.c
+++ b/fs/stat.c
@@ -453,6 +453,10 @@ SYSCALL_DEFINE2(newlstat, const char __user *, filename,
 	return cp_new_stat(&stat, statbuf);
 }
 
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+extern __attribute__((hot, always_inline)) int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
+#endif
+
 #if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)
 SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
 		struct stat __user *, statbuf, int, flag)
@@ -460,6 +464,9 @@ SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
 	struct kstat stat;
 	int error;
 
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+	ksu_handle_stat(&dfd, &filename, &flag);
+#endif
 	error = vfs_fstatat(dfd, filename, &stat, flag);
 	if (error)
 		return error;
@@ -611,6 +618,9 @@ SYSCALL_DEFINE4(fstatat64, int, dfd, const char __user *, filename,
 	struct kstat stat;
 	int error;
 
+#if defined(CONFIG_KSU) && !defined(CONFIG_KSU_KPROBES_HOOK)
+	ksu_handle_stat(&dfd, &filename, &flag);
+#endif
 	error = vfs_fstatat(dfd, filename, &stat, flag);
 	if (error)
 		return error;
EOF

echo "Patches generated successfully."
