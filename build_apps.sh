#!/bin/bash
set -e

echo "=== Biên dịch các ứng dụng hệ thống (apps) ==="

# Thư mục chứa các ứng dụng
APPS_DIR="$(pwd)/apps"

# 1. Kiểm tra Git Submodule
if [ ! -f "$APPS_DIR/smithay/Cargo.toml" ]; then
    echo "Phát hiện thư mục apps/smithay trống. Đang khởi tạo Git Submodules..."
    # Cho phép giao thức file phòng trường hợp dùng local repo
    git -c protocol.file.allow=always submodule update --init --recursive
fi

# Thiết lập các biến môi trường để trỏ vào thư viện hệ thống custom
export PKG_CONFIG_PATH=/tmp/local_libs/usr/lib/x86_64-linux-gnu/pkgconfig
export RUSTFLAGS="-L /tmp/local_libs/usr/lib/x86_64-linux-gnu"

# 2. Biên dịch Anvil (Compositor)
echo "--- Đang biên dịch Smithay Anvil (Wayland Compositor) ---"
cd "$APPS_DIR/smithay"

# Biên dịch Anvil với tùy chọn no-xwayland và egl+udev
cargo build --release -p anvil --bin anvil --no-default-features --features "egl udev"

# Biên dịch test client Wayland
echo "--- Đang biên dịch test client Wayland ---"
cargo build --release -p test_clients --bin test_xdg_map_unmap
cargo build --release -p test_clients --bin app_manager
cargo build --release -p test_clients --bin rust_dock
cargo build --release -p test_clients --bin rust_terminal

echo "=== Biên dịch thành công các ứng dụng! ==="
