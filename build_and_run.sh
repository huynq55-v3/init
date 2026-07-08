#!/bin/bash
set -e

# Xác định Kernel Linux để lấy phiên bản (KVER) cho việc sao chép driver module
KERNEL=$(ls -v /boot/vmlinuz-* 2>/dev/null | tail -n 1)
if [ -z "$KERNEL" ]; then
    echo "LỖI: Không tìm thấy file vmlinuz-* trong /boot/."
    exit 1
fi
KVER=$(echo "$KERNEL" | sed 's/.*vmlinuz-//')
echo "Đã xác định Kernel: $KERNEL (phiên bản $KVER)"

echo "=== Bước 1: Biên dịch các ứng dụng và init binary ==="
# Biên dịch các ứng dụng hệ thống (Anvil, test client)
./build_apps.sh

# Biên dịch dự án init
cargo build --release

echo "=== Bước 2: Chuẩn bị rootfs ==="
rm -rf my-rootfs
mkdir -p my-rootfs/{bin,sbin,etc,proc,sys,dev,tmp,run,root,usr/share/X11,home/huy}

# Copy cấu hình passwd và group cho user system
cp passwd my-rootfs/etc/passwd
cp group my-rootfs/etc/group

# Copy binary init vào rootfs dưới tên /init
cp target/release/init my-rootfs/init
chmod +x my-rootfs/init

# Copy binary anvil (Wayland compositor) vào rootfs từ thư mục build của submodule
if [ -f apps/smithay/target/release/anvil ]; then
    echo "Đã tìm thấy Anvil binary tại apps/smithay/target/release/anvil"
    cp apps/smithay/target/release/anvil my-rootfs/bin/anvil
    chmod +x my-rootfs/bin/anvil
else
    echo "LỖI: Chưa build xong Anvil compositor!"
    exit 1
fi

# Copy binary test client vào rootfs từ thư mục build của submodule
if [ -f apps/smithay/target/release/test_xdg_map_unmap ]; then
    echo "Đã tìm thấy test client Wayland tại apps/smithay/target/release/test_xdg_map_unmap"
    cp apps/smithay/target/release/test_xdg_map_unmap my-rootfs/bin/test_xdg_map_unmap
    chmod +x my-rootfs/bin/test_xdg_map_unmap
else
    echo "LỖI: Chưa build xong test client Wayland!"
    exit 1
fi

# Copy app-manager và rust-dock
if [ -f apps/smithay/target/release/app_manager ]; then
    echo "Đã tìm thấy app-manager tại apps/smithay/target/release/app_manager"
    cp apps/smithay/target/release/app_manager my-rootfs/bin/app-manager
    chmod +x my-rootfs/bin/app-manager
fi

if [ -f apps/smithay/target/release/rust_dock ]; then
    echo "Đã tìm thấy rust-dock tại apps/smithay/target/release/rust_dock"
    cp apps/smithay/target/release/rust_dock my-rootfs/bin/rust-dock
    chmod +x my-rootfs/bin/rust-dock
fi

if [ -f apps/smithay/target/release/rust_terminal ]; then
    echo "Đã tìm thấy rust-terminal tại apps/smithay/target/release/rust_terminal"
    cp apps/smithay/target/release/rust_terminal my-rootfs/bin/rust-terminal
    chmod +x my-rootfs/bin/rust-terminal

    # Tạo App Bundle cho rust-terminal để được quét bởi app-manager
    echo "Tạo App Bundle cho rust-terminal tại my-rootfs/apps/rust_terminal..."
    mkdir -p my-rootfs/apps/rust_terminal
    cat << 'EOF' > my-rootfs/apps/rust_terminal/app.toml
[application]
name = "Terminal"
exec = "/bin/rust-terminal"
icon = ""
category = "System"
version = "1.0.0"
EOF
fi

# Tích hợp BusyBox để có đầy đủ các lệnh UNIX chuẩn (ls, cat, mkdir...)
echo "Tích hợp BusyBox và tạo các lệnh UNIX chuẩn..."
cp /usr/bin/busybox my-rootfs/bin/busybox
chmod +x my-rootfs/bin/busybox

# Tạo các link lệnh chuẩn trỏ về busybox dạng relative (bỏ qua chính busybox)
for cmd in $(my-rootfs/bin/busybox --list); do
    if [ "$cmd" != "busybox" ]; then
        ln -sf busybox my-rootfs/bin/$cmd
    fi
done

# Tạo một file văn bản nhỏ trong rootfs để test lệnh 'cat'
echo "Xin chào! Đây là file test nằm trong Rust user space." > my-rootfs/root/hello.txt

# Copy bàn phím layout cho xkb (yêu cầu bởi libxkbcommon của Anvil)
if [ -d /usr/share/X11/xkb ]; then
    echo "Copying keyboard layouts (xkb)..."
    mkdir -p my-rootfs/usr/share/X11
    cp -rL /usr/share/X11/xkb my-rootfs/usr/share/X11/xkb
fi

echo "=== Bước 3: Phân tích và tự động copy các file thư viện liên kết động (.so) ==="
copy_deps() {
    local bin="$1"
    local dest="$2"
    echo "Phân tích dependencies cho: $bin"
    
    # Sử dụng ldd để lấy danh sách các file thư viện liên kết động (.so)
    # Lọc ra các đường dẫn tuyệt đối (bắt đầu bằng /)
    ldd "$bin" | grep -o '/[a-zA-Z0-9_.+-]\+\(/[a-zA-Z0-9_.+-]\+\)*' | while read -r lib; do
        if [ -f "$lib" ]; then
            local dir_path=$(dirname "$lib")
            mkdir -p "$dest$dir_path"
            cp -L "$lib" "$dest$lib"
        fi
    done
}

# Sao chép các dependency cho các binary
copy_deps my-rootfs/init my-rootfs
copy_deps my-rootfs/bin/anvil my-rootfs
copy_deps my-rootfs/bin/test_xdg_map_unmap my-rootfs
copy_deps my-rootfs/bin/app-manager my-rootfs
copy_deps my-rootfs/bin/rust-dock my-rootfs
copy_deps my-rootfs/bin/rust-terminal my-rootfs

# Copy thêm libseat.so.1 thủ công (vì nó nằm trong thư mục build tạm của chúng ta)
if [ -f /tmp/local_libs/usr/lib/x86_64-linux-gnu/libseat.so.1 ]; then
    echo "Sao chép libseat.so.1 thủ công từ thư mục tạm..."
    mkdir -p my-rootfs/lib/x86_64-linux-gnu
    cp -L /tmp/local_libs/usr/lib/x86_64-linux-gnu/libseat.so.1 my-rootfs/lib/x86_64-linux-gnu/libseat.so.1
    # Tạo symlink cần thiết
    ln -sf libseat.so.1 my-rootfs/lib/x86_64-linux-gnu/libseat.so
fi

# Copy thêm libdisplay-info.so.3 thủ công (vì nó cũng nằm trong thư mục build tạm)
if [ -f /tmp/local_libs/usr/lib/x86_64-linux-gnu/libdisplay-info.so.3 ]; then
    echo "Sao chép libdisplay-info.so.3 thủ công từ thư mục tạm..."
    mkdir -p my-rootfs/lib/x86_64-linux-gnu
    cp -L /tmp/local_libs/usr/lib/x86_64-linux-gnu/libdisplay-info.so.3 my-rootfs/lib/x86_64-linux-gnu/libdisplay-info.so.3
    # Tạo symlink cần thiết
    ln -sf libdisplay-info.so.3 my-rootfs/lib/x86_64-linux-gnu/libdisplay-info.so
fi

# Copy thêm libinput.so.10 thủ công (vì nó nằm trong thư mục build tạm)
if [ -f /tmp/local_libs/usr/lib/x86_64-linux-gnu/libinput.so.10 ]; then
    echo "Sao chép libinput.so.10 thủ công từ thư mục tạm..."
    mkdir -p my-rootfs/lib/x86_64-linux-gnu
    cp -L /tmp/local_libs/usr/lib/x86_64-linux-gnu/libinput.so.10 my-rootfs/lib/x86_64-linux-gnu/libinput.so.10
    # Tạo symlink cần thiết
    ln -sf libinput.so.10 my-rootfs/lib/x86_64-linux-gnu/libinput.so
fi

# Copy thêm libpixman-1.so.0 thủ công (vì nó nằm trong thư mục build tạm)
if [ -f /tmp/local_libs/usr/lib/x86_64-linux-gnu/libpixman-1.so.0 ]; then
    echo "Sao chép libpixman-1.so.0 thủ công từ thư mục tạm..."
    mkdir -p my-rootfs/lib/x86_64-linux-gnu
    cp -L /tmp/local_libs/usr/lib/x86_64-linux-gnu/libpixman-1.so.0 my-rootfs/lib/x86_64-linux-gnu/libpixman-1.so.0
    # Tạo symlink cần thiết
    ln -sf libpixman-1.so.0 my-rootfs/lib/x86_64-linux-gnu/libpixman-1.so
fi

echo "=== Sao chép các thư viện Wayland, EGL/OpenGL và Mesa DRI ==="
mkdir -p my-rootfs/usr/lib/x86_64-linux-gnu/dri

# Copy libwayland vì chúng được load động (dlopen) tại runtime
cp -L /usr/lib/x86_64-linux-gnu/libwayland-*.so* my-rootfs/usr/lib/x86_64-linux-gnu/

# Copy các thư viện đồ họa EGL/OpenGL
cp -L /usr/lib/x86_64-linux-gnu/libEGL.so* my-rootfs/usr/lib/x86_64-linux-gnu/
cp -L /usr/lib/x86_64-linux-gnu/libGLESv2.so* my-rootfs/usr/lib/x86_64-linux-gnu/
cp -L /usr/lib/x86_64-linux-gnu/libGL.so* my-rootfs/usr/lib/x86_64-linux-gnu/
cp -L /usr/lib/x86_64-linux-gnu/libEGL_mesa.so* my-rootfs/usr/lib/x86_64-linux-gnu/

# Copy Mesa DRI drivers (giữ nguyên symlink bằng cp -d để tránh trùng lặp libgallium.so nặng)
cp -d /usr/lib/x86_64-linux-gnu/dri/*.so my-rootfs/usr/lib/x86_64-linux-gnu/dri/

# Copy Mesa GBM backend (yêu cầu bởi libgbm để khởi tạo card đồ họa)
mkdir -p my-rootfs/usr/lib/x86_64-linux-gnu/gbm
cp -L /usr/lib/x86_64-linux-gnu/gbm/*.so my-rootfs/usr/lib/x86_64-linux-gnu/gbm/

# Copy libinput quirks data files để tránh warning lúc khởi chạy thiết bị đầu vào
if [ -d /usr/share/libinput ]; then
    mkdir -p my-rootfs/usr/share/libinput
    cp -r /usr/share/libinput/* my-rootfs/usr/share/libinput/
fi

# Copy GLVND vendor configurations so EGL dispatcher knows to load Mesa EGL
if [ -d /usr/share/glvnd ]; then
    mkdir -p my-rootfs/usr/share/glvnd
    cp -r /usr/share/glvnd/* my-rootfs/usr/share/glvnd/
fi

# Quét và copy toàn bộ dependencies bắc cầu của các thư viện đồ họa vừa copy
find my-rootfs/usr/lib/x86_64-linux-gnu/ -name "*.so*" -type f | while read -r lib_file; do
    copy_deps "$lib_file" my-rootfs
done

echo "=== Sao chép driver module đồ họa và nhập liệu (GPU, USB, Input) ==="
# Định nghĩa hàm đệ quy để copy module và toàn bộ dependency của nó
copy_module_with_deps() {
    local mod_name="$1"
    # Tìm đường dẫn của module trên host
    local mod_path=$(modinfo -n "$mod_name" 2>/dev/null || true)
    if [ -z "$mod_path" ]; then
        return
    fi
    
    # Tính toán đường dẫn tương đối trong rootfs
    local rel_path=${mod_path#/lib/modules/$KVER/}
    
    # Tránh copy lại nếu đã tồn tại
    if [ -f "my-rootfs/lib/modules/$KVER/$rel_path" ]; then
        return
    fi
    
    # Copy module chính
    mkdir -p "my-rootfs/lib/modules/$KVER/$(dirname "$rel_path")"
    cp -L "$mod_path" "my-rootfs/lib/modules/$KVER/$rel_path"
    
    # Quét dependencies của module này
    local deps=$(modinfo -F depends "$mod_name" 2>/dev/null | tr ',' ' ' || true)
    for dep in $deps; do
        if [ -n "$dep" ]; then
            copy_module_with_deps "$dep"
        fi
    done
}

# Copy các module đồ họa chính
copy_module_with_deps virtio-gpu
copy_module_with_deps i915
copy_module_with_deps xe
copy_module_with_deps amdgpu
copy_module_with_deps nouveau

# Copy các module thiết bị đầu vào chính
copy_module_with_deps usbhid
copy_module_with_deps hid-generic
copy_module_with_deps psmouse
copy_module_with_deps i2c-hid-acpi
copy_module_with_deps hid-multitouch
copy_module_with_deps intel-lpss-pci
copy_module_with_deps intel-lpss-acpi
copy_module_with_deps i2c-designware-pci

# Copy các module lưu trữ chính (NVMe SSD, SATA/AHCI HDD/SSD, SD Card, VMD Controller)
copy_module_with_deps nvme
copy_module_with_deps ahci
copy_module_with_deps sdhci
copy_module_with_deps sdhci-pci
copy_module_with_deps vmd

# Copy kmod (để cung cấp lệnh modprobe nạp module trong VM)
cp /usr/bin/kmod my-rootfs/bin/kmod
ln -sf kmod my-rootfs/bin/modprobe
ln -sf kmod my-rootfs/bin/depmod

# Quét dependency cho kmod để copy các thư viện .so cần thiết
copy_deps my-rootfs/bin/kmod my-rootfs

# Copy udev daemon và udevadm cho việc quản lý nóng thiết bị đầu vào (chuột/bàn phím)
mkdir -p my-rootfs/lib/systemd
cp -L /lib/systemd/systemd-udevd my-rootfs/lib/systemd/systemd-udevd
cp -L /usr/bin/udevadm my-rootfs/bin/udevadm

# Copy dependencies của udevd và udevadm
copy_deps my-rootfs/lib/systemd/systemd-udevd my-rootfs
copy_deps my-rootfs/bin/udevadm my-rootfs

# Copy libkmod.so.2 thủ công vì udevadm/udevd sử dụng dlopen để load nó
mkdir -p my-rootfs/usr/lib/x86_64-linux-gnu
cp -L /usr/lib/x86_64-linux-gnu/libkmod.so.2 my-rootfs/usr/lib/x86_64-linux-gnu/

# Copy các rules của udev và hwdb vào cả /usr/lib/udev và /lib/udev để tương thích hoàn toàn
mkdir -p my-rootfs/usr/lib/udev/rules.d
mkdir -p my-rootfs/lib/udev/rules.d

# Copy udev rules
cp -rL /lib/udev/rules.d/* my-rootfs/usr/lib/udev/rules.d/
cp -rL /lib/udev/rules.d/* my-rootfs/lib/udev/rules.d/

# Copy hwdb.bin
if [ -f /lib/udev/hwdb.bin ]; then
    cp -L /lib/udev/hwdb.bin my-rootfs/usr/lib/udev/hwdb.bin
    cp -L /lib/udev/hwdb.bin my-rootfs/lib/udev/hwdb.bin
elif [ -f /usr/lib/udev/hwdb.bin ]; then
    cp -L /usr/lib/udev/hwdb.bin my-rootfs/usr/lib/udev/hwdb.bin
    cp -L /usr/lib/udev/hwdb.bin my-rootfs/lib/udev/hwdb.bin
fi

# Thêm rule udev bắt buộc gán nhãn seat0
cat << 'EOF' > my-rootfs/usr/lib/udev/rules.d/99-seat0.rules
SUBSYSTEM=="input", KERNEL=="input*", TAG+="seat0", ENV{ID_SEAT}="seat0"
SUBSYSTEM=="drm", KERNEL=="card*", TAG+="seat0", ENV{ID_SEAT}="seat0"
EOF
cp my-rootfs/usr/lib/udev/rules.d/99-seat0.rules my-rootfs/lib/udev/rules.d/99-seat0.rules

# Chạy depmod trên host để thiết lập index danh sách phụ thuộc cho các module trong rootfs
depmod -b my-rootfs "$KVER"

echo "=== Sao chép firmware cho Intel GPU (i915 và xe) ==="
mkdir -p my-rootfs/lib/firmware
if [ -d /lib/firmware/i915 ]; then
    cp -r /lib/firmware/i915 my-rootfs/lib/firmware/
fi
if [ -d /lib/firmware/xe ]; then
    cp -r /lib/firmware/xe my-rootfs/lib/firmware/
fi

echo "=== Bước 4: Đóng gói thành initramfs ==="
cd my-rootfs
find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../initramfs.cpio.gz
cd ..

echo "=== Tạo phân vùng dữ liệu ảo ext4 cho QEMU ==="
if [ ! -f data.img ]; then
    echo "Tạo file ảnh đĩa ảo data.img..."
    dd if=/dev/zero of=data.img bs=1M count=100
    mkfs.ext4 -F data.img
fi

echo "=== Tạo Live ISO Bootable (rust-os.iso) ==="
if command -v mformat >/dev/null 2>&1; then
    rm -rf iso_staging
    mkdir -p iso_staging/boot/grub
    cp "$KERNEL" iso_staging/boot/vmlinuz
    cp initramfs.cpio.gz iso_staging/boot/initrd.img

    cat <<EOF > iso_staging/boot/grub/grub.cfg
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console

set default=0
set timeout=1

menuentry "Rust-only OS (Bare-metal Live ISO)" {
    linux /boot/vmlinuz console=tty1 console=ttyS0 quiet init=/init
    initrd /boot/initrd.img
}
EOF

    if grub-mkrescue -o rust-os.iso iso_staging; then
        echo "=== Đã tạo xong Live ISO: rust-os.iso ==="
    else
        echo "Cảnh báo: Lỗi khi chạy grub-mkrescue. Không thể tạo Live ISO."
    fi
    rm -rf iso_staging
else
    echo "========================================================================"
    echo "Cảnh báo: mformat (mtools) chưa được cài đặt trên hệ thống."
    echo "Không thể tạo Live ISO (rust-os.iso) vì thiếu công cụ tạo phân vùng EFI."
    echo "Vui lòng cài đặt bằng lệnh:"
    echo "    sudo apt update && sudo apt install -y mtools"
    echo ""
    echo "Bỏ qua tạo ISO. Tiến trình đóng gói initramfs vẫn hoàn tất."
    echo "========================================================================"
fi

echo "=== Bước 5: Xác nhận Kernel Linux ==="
echo "Sử dụng kernel: $KERNEL"

echo "=== Bước 6: Khởi chạy QEMU ==="
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    KVM_FLAG=""
    if [ -w /dev/kvm ]; then
        echo "KVM khả dụng, kích hoạt tăng tốc phần cứng..."
        KVM_FLAG="-enable-kvm"
    fi
    
    echo "Khởi động QEMU ở chế độ đồ họa..."
    echo "MẸO: Shell dòng lệnh tương tác sẽ chạy trực tiếp ngay tại terminal này."
    echo "Cửa sổ đồ họa QEMU sẽ hiển thị giao diện Wayland Compositor (Anvil)."
    echo "Đang khởi chạy..."
    sleep 2
    
    # Tránh lỗi xung đột thư viện động khi chạy QEMU từ terminal của VS Code / IDE cài qua Snap
    unset LD_LIBRARY_PATH
    unset LD_PRELOAD

    qemu-system-x86_64 \
        $KVM_FLAG \
        -m 2048 \
        -kernel "$KERNEL" \
        -initrd initramfs.cpio.gz \
        -append "console=ttyS0 quiet init=/init" \
        -vga virtio \
        -usb -device usb-tablet \
        -drive file=data.img,format=raw,if=virtio \
        -serial stdio
else
    echo "========================================================================"
    echo "Cảnh báo: QEMU (qemu-system-x86_64) chưa được cài đặt trên hệ thống."
    echo "Vui lòng cài đặt QEMU bằng lệnh:"
    echo "    sudo apt update && sudo apt install -y qemu-system-x86"
    echo ""
    echo "Sau khi cài đặt, bạn có thể tự khởi chạy thủ công bằng lệnh:"
    echo "    qemu-system-x86_64 -m 2048 -kernel \$KERNEL -initrd initramfs.cpio.gz -append \"console=ttyS0 quiet init=/init\" -vga virtio -usb -device usb-tablet -serial stdio"
    echo "========================================================================"
fi
