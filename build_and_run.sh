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

echo "=== Bước 1: Biên dịch Rust init binary (dynamic linking GNU) ==="
cargo build --release

echo "=== Bước 2: Chuẩn bị rootfs ==="
rm -rf my-rootfs
mkdir -p my-rootfs/{bin,sbin,etc,proc,sys,dev,tmp,run,root,usr/share/X11}

# Copy binary init vào rootfs dưới tên /init
cp target/release/init my-rootfs/init
chmod +x my-rootfs/init

# Copy binary anvil (Wayland compositor) vào rootfs
if [ -f /tmp/smithay/target/release/anvil ]; then
    echo "Đã tìm thấy Anvil binary tại /tmp/smithay/target/release/anvil"
    cp /tmp/smithay/target/release/anvil my-rootfs/bin/anvil
    chmod +x my-rootfs/bin/anvil
else
    echo "LỖI: Chưa build xong Anvil compositor tại /tmp/smithay/target/release/anvil!"
    exit 1
fi

# Copy binary test client (Wayland client) vào rootfs
if [ -f /tmp/smithay/target/release/test_xdg_map_unmap ]; then
    echo "Đã tìm thấy test client Wayland tại /tmp/smithay/target/release/test_xdg_map_unmap"
    cp /tmp/smithay/target/release/test_xdg_map_unmap my-rootfs/bin/test_xdg_map_unmap
    chmod +x my-rootfs/bin/test_xdg_map_unmap
else
    echo "LỖI: Chưa build xong test client Wayland!"
    exit 1
fi

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

# Sao chép các dependency cho init, anvil và test client
copy_deps my-rootfs/init my-rootfs
copy_deps my-rootfs/bin/anvil my-rootfs
copy_deps my-rootfs/bin/test_xdg_map_unmap my-rootfs

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

echo "=== Sao chép driver module đồ họa (virtio-gpu) ==="
# Tạo thư mục chứa các module tương ứng cho kernel target
mkdir -p "my-rootfs/lib/modules/$KVER/kernel/drivers/virtio"
mkdir -p "my-rootfs/lib/modules/$KVER/kernel/drivers/gpu/drm/virtio"

# Copy các module và các dependency đã xác định
cp "/lib/modules/$KVER/kernel/drivers/virtio/virtio_dma_buf.ko.zst" "my-rootfs/lib/modules/$KVER/kernel/drivers/virtio/"
cp "/lib/modules/$KVER/kernel/drivers/gpu/drm/virtio/virtio-gpu.ko.zst" "my-rootfs/lib/modules/$KVER/kernel/drivers/gpu/drm/virtio/"

# Copy kmod (để cung cấp lệnh modprobe nạp module trong VM)
cp /usr/bin/kmod my-rootfs/bin/kmod
ln -sf kmod my-rootfs/bin/modprobe
ln -sf kmod my-rootfs/bin/depmod

# Quét dependency cho kmod để copy các thư viện .so cần thiết
copy_deps my-rootfs/bin/kmod my-rootfs

# Chạy depmod trên host để thiết lập index danh sách phụ thuộc cho các module trong rootfs
depmod -b my-rootfs "$KVER"

echo "=== Bước 4: Đóng gói thành initramfs ==="
cd my-rootfs
find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../initramfs.cpio.gz
cd ..

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
