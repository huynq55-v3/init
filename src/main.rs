use std::ffi::CString;
use std::ptr;
use std::io::{self, Write};
use std::path::Path;
use std::process::Command;

fn mount_fs(source: &str, target: &str, fstype: &str, flags: libc::c_ulong) -> Result<(), std::io::Error> {
    let c_source = CString::new(source)?;
    let c_target = CString::new(target)?;
    let c_fstype = CString::new(fstype)?;
    let res = unsafe {
        libc::mount(
            c_source.as_ptr(),
            c_target.as_ptr(),
            c_fstype.as_ptr(),
            flags,
            ptr::null(),
        )
    };
    if res == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn setup_mounts() {
    println!("[init] Đang chuẩn bị các mount point...");
    let mounts = [
        ("proc", "/proc", "proc", 0),
        ("sysfs", "/sys", "sysfs", 0),
        ("devtmpfs", "/dev", "devtmpfs", 0),
        ("devpts", "/dev/pts", "devpts", 0),
        ("tmpfs", "/tmp", "tmpfs", 0),
        ("tmpfs", "/run", "tmpfs", 0),
    ];

    for (source, target, fstype, flags) in mounts.iter() {
        let path = Path::new(target);
        if !path.exists() {
            if let Err(e) = std::fs::create_dir_all(path) {
                eprintln!("[init] Lỗi tạo thư mục {}: {}", target, e);
                continue;
            }
        }
        match mount_fs(source, target, fstype, *flags) {
            Ok(_) => println!("[init] Đã mount {} vào {}", fstype, target),
            Err(e) => eprintln!("[init] Cảnh báo: Lỗi mount {} vào {}: {}", fstype, target, e),
        }
    }

    // Tạo thư mục đặc biệt cho XWayland sockets trong /tmp
    if let Err(e) = std::fs::create_dir_all("/tmp/.X11-unix") {
        eprintln!("[init] Lỗi tạo /tmp/.X11-unix: {}", e);
    } else {
        unsafe {
            libc::chmod(b"/tmp/.X11-unix\0".as_ptr() as *const libc::c_char, 0o1777);
        }
    }

    // Đảm bảo quyền truy cập cho /dev/ptmx là 0666 để user thường có thể mở PTY
    let ptmx_path = "/dev/ptmx";
    if Path::new(ptmx_path).exists() {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(metadata) = std::fs::metadata(ptmx_path) {
            let mut perms = metadata.permissions();
            perms.set_mode(0o666);
            if let Err(e) = std::fs::set_permissions(ptmx_path, perms) {
                eprintln!("[init] Cảnh báo: Lỗi chmod /dev/ptmx: {}", e);
            } else {
                println!("[init] Đã thiết lập quyền 0666 cho /dev/ptmx");
            }
        }
    }
}

fn list_processes() {
    println!("  {:5} {:10} {}", "PID", "STAT", "COMMAND");
    match std::fs::read_dir("/proc") {
        Ok(entries) => {
            for entry in entries {
                if let Ok(entry) = entry {
                    let name = entry.file_name();
                    let name_str = name.to_string_lossy();
                    if name_str.chars().all(|c| c.is_ascii_digit()) {
                        let pid = &name_str;
                        let cmdline_path = format!("/proc/{}/cmdline", pid);
                        let cmd = std::fs::read_to_string(&cmdline_path)
                            .map(|mut s| {
                                s.retain(|c| c != '\0');
                                if s.is_empty() {
                                    let stat_path = format!("/proc/{}/stat", pid);
                                    if let Ok(stat) = std::fs::read_to_string(&stat_path) {
                                        if let Some(start) = stat.find('(') {
                                            if let Some(end) = stat.find(')') {
                                                return stat[start+1..end].to_string();
                                            }
                                        }
                                    }
                                    "unknown".to_string()
                                } else {
                                    s
                                }
                            })
                            .unwrap_or_else(|_| "unknown".to_string());
                        
                        let stat_path = format!("/proc/{}/stat", pid);
                        let state = std::fs::read_to_string(&stat_path)
                            .map(|s| {
                                let parts: Vec<&str> = s.split_whitespace().collect();
                                if parts.len() > 2 {
                                    parts[2].to_string()
                                } else {
                                    "-".to_string()
                                }
                            })
                            .unwrap_or_else(|_| "-".to_string());

                        println!("  {:5} {:10} {}", pid, state, cmd);
                    }
                }
            }
        }
        Err(e) => eprintln!("ps: Lỗi đọc /proc: {}", e),
    }
}

fn run_shell() {
    println!("\n--- Chào mừng đến với Rust-only User Space OS! ---");
    println!("Gõ 'help' để xem các lệnh có sẵn.\n");

    loop {
        let current_dir = std::env::current_dir()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".to_string());

        print!("rust-os:{}# ", current_dir);
        if let Err(e) = io::stdout().flush() {
            eprintln!("Lỗi stdout flush: {}", e);
        }

        let mut input = String::new();
        if io::stdin().read_line(&mut input).is_err() {
            eprintln!("Lỗi đọc stdin!");
            continue;
        }

        let trimmed = input.trim();
        if trimmed.is_empty() {
            continue;
        }

        let parts: Vec<&str> = trimmed.split_whitespace().collect();
        let cmd = parts[0];
        let args = &parts[1..];

        match cmd {
            "help" => {
                println!("Các lệnh có sẵn:");
                println!("  help            Hiển thị thông báo này");
                println!("  ls [thư mục]    Liệt kê nội dung thư mục");
                println!("  cd <thư mục>    Chuyển thư mục làm việc");
                println!("  pwd             Hiển thị thư mục hiện tại");
                println!("  cat <file>      Hiển thị nội dung file");
                println!("  echo [chuỗi]    In ra chuỗi ký tự");
                println!("  mkdir <thư mục> Tạo thư mục mới");
                println!("  rm <đường dẫn>  Xóa file hoặc thư mục");
                println!("  ps              Liệt kê các tiến trình đang chạy");
                println!("  df              Hiển thị các phân vùng đã mount");
                println!("  uname           Hiển thị thông tin hệ thống");
                println!("  reboot          Khởi động lại hệ thống");
                println!("  poweroff        Tắt máy ảo");
            }
            "ls" => {
                let target = args.first().copied().unwrap_or(".");
                match std::fs::read_dir(target) {
                    Ok(entries) => {
                        for entry in entries {
                            if let Ok(entry) = entry {
                                let metadata = entry.metadata();
                                let file_name = entry.file_name();
                                let name = file_name.to_string_lossy();
                                let file_type = if metadata.as_ref().map(|m| m.is_dir()).unwrap_or(false) {
                                    "DIR "
                                } else {
                                    "FILE"
                                };
                                let size = metadata.as_ref().map(|m| m.len()).unwrap_or(0);
                                println!("  {} {:10} B  {}", file_type, size, name);
                            }
                        }
                    }
                    Err(e) => eprintln!("ls: không thể đọc '{}': {}", target, e),
                }
            }
            "cd" => {
                if args.is_empty() {
                    println!("cd: thiếu đường dẫn");
                } else {
                    let target = args[0];
                    if let Err(e) = std::env::set_current_dir(target) {
                        eprintln!("cd: không thể chuyển đến '{}': {}", target, e);
                    }
                }
            }
            "pwd" => {
                println!("{}", current_dir);
            }
            "cat" => {
                if args.is_empty() {
                    println!("cat: thiếu đường dẫn file");
                } else {
                    let target = args[0];
                    match std::fs::read_to_string(target) {
                        Ok(content) => print!("{}", content),
                        Err(e) => eprintln!("cat: không thể đọc '{}': {}", target, e),
                    }
                }
            }
            "echo" => {
                println!("{}", args.join(" "));
            }
            "mkdir" => {
                if args.is_empty() {
                    println!("mkdir: thiếu tên thư mục");
                } else {
                    let target = args[0];
                    if let Err(e) = std::fs::create_dir_all(target) {
                        eprintln!("mkdir: không thể tạo '{}': {}", target, e);
                    }
                }
            }
            "rm" => {
                if args.is_empty() {
                    println!("rm: thiếu đường dẫn");
                } else {
                    let target = args[0];
                    let path = Path::new(target);
                    if path.is_dir() {
                        if let Err(e) = std::fs::remove_dir_all(target) {
                            eprintln!("rm: không thể xóa thư mục '{}': {}", target, e);
                        }
                    } else {
                        if let Err(e) = std::fs::remove_file(target) {
                            eprintln!("rm: không thể xóa file '{}': {}", target, e);
                        }
                    }
                }
            }
            "uname" => {
                if let Ok(content) = std::fs::read_to_string("/proc/version") {
                    print!("{}", content);
                } else {
                    println!("Linux (Rust-only User Space OS)");
                }
            }
            "df" => {
                if let Ok(content) = std::fs::read_to_string("/proc/mounts") {
                    println!("{}", content);
                } else {
                    eprintln!("df: không thể đọc /proc/mounts (bạn đã mount /proc chưa?)");
                }
            }
            "ps" => {
                list_processes();
            }
            "reboot" => {
                println!("Đang khởi động lại...");
                unsafe {
                    libc::reboot(libc::LINUX_REBOOT_CMD_RESTART);
                }
            }
            "poweroff" => {
                println!("Đang tắt hệ thống...");
                unsafe {
                    libc::reboot(libc::LINUX_REBOOT_CMD_POWER_OFF);
                }
            }
            _ => {
                match Command::new(cmd).args(args).spawn() {
                    Ok(mut child) => {
                        if let Err(e) = child.wait() {
                            eprintln!("{}: lỗi trong khi chạy: {}", cmd, e);
                        }
                    }
                    Err(_) => {
                        println!("rust-shell: không tìm thấy lệnh: '{}'", cmd);
                    }
                }
            }
        }
    }
}

fn start_anvil() {
    println!("[init] Đang tạo thư mục /run/user/0 cho Wayland...");
    if let Err(e) = std::fs::create_dir_all("/run/user/0") {
        eprintln!("[init] Lỗi tạo /run/user/0: {}", e);
    } else {
        unsafe {
            libc::chmod(b"/run/user/0\0".as_ptr() as *const libc::c_char, 0o700);
        }
    }

    println!("[init] Khởi chạy Wayland Compositor (Anvil) trên card đồ họa ảo (KMS/DRM)...");
    
    // Tìm card DRM trong /dev/dri/
    let mut drm_device = "/dev/dri/card0".to_string();
    if let Ok(entries) = std::fs::read_dir("/dev/dri") {
        let mut found_cards = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with("card") {
                found_cards.push(format!("/dev/dri/{}", name));
            }
        }
        found_cards.sort();
        if let Some(card) = found_cards.first() {
            println!("[init] Tự động phát hiện card DRM: {}", card);
            drm_device = card.clone();
        } else {
            println!("[init] Cảnh báo: Không tìm thấy card nào bắt đầu bằng 'card' trong /dev/dri. Sử dụng mặc định /dev/dri/card0.");
        }
    } else {
        println!("[init] Cảnh báo: Thư mục /dev/dri không tồn tại. Sử dụng mặc định /dev/dri/card0.");
    }

    // Khởi chạy anvil ở chế độ --tty-udev (direct TTY/DRM/KMS)
    let mut anvil_cmd = Command::new("/bin/anvil");
    anvil_cmd.arg("--tty-udev");
    
    // Đặt biến môi trường bắt buộc cho Wayland và cấu hình GPU target
    anvil_cmd.env("ANVIL_DRM_DEVICE", &drm_device);
    
    // Ép buộc libseat sử dụng builtin backend trực tiếp với quyền root
    anvil_cmd.env("LIBSEAT_BACKEND", "builtin");
    
    // Mở /dev/tty1 làm stdin (controlling terminal) cho Anvil để libseat hoạt động đúng đắn
    if let Ok(file) = std::fs::OpenOptions::new().read(true).write(true).open("/dev/tty1") {
        println!("[init] Gán /dev/tty1 làm stdin cho Anvil Compositor.");
        anvil_cmd.stdin(file);
    } else {
        eprintln!("[init] Cảnh báo: Lỗi mở /dev/tty1 làm stdin.");
    }

    // Ghi log Anvil ra phân vùng lưu trữ bền vững để dễ dàng gỡ lỗi trên host
    let log_file_path = "/home/huy/anvil.log";
    match std::fs::OpenOptions::new().create(true).write(true).truncate(true).open(log_file_path) {
        Ok(log_file) => {
            println!("[init] Ghi nhật ký Anvil vào {}", log_file_path);
            anvil_cmd.stdout(log_file.try_clone().unwrap());
            anvil_cmd.stderr(log_file);
        }
        Err(e) => {
            eprintln!("[init] Không thể tạo file log Anvil: {}. Dùng console mặc định.", e);
        }
    }

    unsafe {
        std::env::set_var("XDG_RUNTIME_DIR", "/run/user/0");
    }

    match anvil_cmd.spawn() {
        Ok(mut child) => {
            println!("[init] Anvil Compositor đã khởi động dưới nền với PID {}", child.id());
            std::thread::spawn(move || {
                match child.wait() {
                    Ok(status) => {
                        println!("[init] Anvil Compositor đã dừng với trạng thái: {}", status);
                        unsafe { libc::sync(); }
                    }
                    Err(e) => {
                        eprintln!("[init] Lỗi trong khi chờ Anvil: {}", e);
                        unsafe { libc::sync(); }
                    }
                }
            });
        }
        Err(e) => {
            eprintln!("[init] Lỗi khởi chạy /bin/anvil: {}", e);
        }
    }
}

fn start_desktop_services() {
    println!("[init] Đang chuẩn bị chạy các dịch vụ giao diện (app-manager, rust-dock, test client)...");
    std::thread::spawn(|| {
        // Đợi 3 giây cho Anvil Compositor khởi động hoàn tất và tạo socket Wayland
        std::thread::sleep(std::time::Duration::from_secs(3));
        
        // Tự động phát hiện socket Wayland thực tế được tạo ra trong /run/user/0
        let mut wayland_display = "wayland-0".to_string();
        if let Ok(entries) = std::fs::read_dir("/run/user/0") {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with("wayland-") && !name.ends_with(".lock") {
                    wayland_display = name;
                    break;
                }
            }
        }

        // 1. Khởi chạy app-manager daemon
        println!("[init] Khởi chạy app-manager daemon...");
        let mut manager_cmd = Command::new("/bin/app-manager");
        manager_cmd.arg("daemon");
        unsafe {
            manager_cmd.env("XDG_RUNTIME_DIR", "/run/user/0");
        }
        let manager_log_path = "/home/huy/app-manager.log";
        if let Ok(log_file) = std::fs::OpenOptions::new().create(true).write(true).truncate(true).open(manager_log_path) {
            manager_cmd.stdout(log_file.try_clone().unwrap());
            manager_cmd.stderr(log_file);
        }
        match manager_cmd.spawn() {
            Ok(child) => println!("[init] app-manager daemon đã khởi chạy với PID {}", child.id()),
            Err(e) => eprintln!("[init] Lỗi khởi chạy app-manager daemon: {}", e),
        }

        // 2. Khởi chạy thanh Dock (rust-dock)
        println!("[init] Khởi chạy thanh Dock (rust-dock)...");
        let mut dock_cmd = Command::new("/bin/rust-dock");
        unsafe {
            dock_cmd.env("XDG_RUNTIME_DIR", "/run/user/0");
            dock_cmd.env("WAYLAND_DISPLAY", &wayland_display);
        }
        let dock_log_path = "/home/huy/dock.log";
        if let Ok(log_file) = std::fs::OpenOptions::new().create(true).write(true).truncate(true).open(dock_log_path) {
            dock_cmd.stdout(log_file.try_clone().unwrap());
            dock_cmd.stderr(log_file);
        }
        match dock_cmd.spawn() {
            Ok(child) => println!("[init] rust-dock đã khởi chạy với PID {}", child.id()),
            Err(e) => eprintln!("[init] Lỗi khởi chạy rust-dock: {}", e),
        }

        // 3. Khởi chạy test client xdg_map_unmap
        println!("[init] Khởi chạy test client kết nối đến display socket: {}...", wayland_display);
        let mut client_cmd = Command::new("/bin/test_xdg_map_unmap");
        unsafe {
            client_cmd.env("XDG_RUNTIME_DIR", "/run/user/0");
            client_cmd.env("WAYLAND_DISPLAY", &wayland_display);
        }
        let client_log_path = "/home/huy/client.log";
        if let Ok(log_file) = std::fs::OpenOptions::new().create(true).write(true).truncate(true).open(client_log_path) {
            client_cmd.stdout(log_file.try_clone().unwrap());
            client_cmd.stderr(log_file);
        }
        match client_cmd.spawn() {
            Ok(mut child) => {
                println!("[init] Test client đã khởi chạy thành công với PID {}", child.id());
                std::thread::spawn(move || {
                    let _ = child.wait();
                    println!("[init] Test client đã thoát.");
                });
            }
            Err(e) => eprintln!("[init] Lỗi khởi chạy test client: {}", e),
        }
    });
}

fn parse_cmdline() -> Option<String> {
    if let Ok(content) = std::fs::read_to_string("/proc/cmdline") {
        for token in content.split_whitespace() {
            if token.starts_with("data_part=") {
                let part = token.trim_start_matches("data_part=");
                return Some(part.to_string());
            }
        }
    }
    None
}

fn setup_user_storage() {
    println!("[init] Đang thiết lập thư mục cá nhân và phân vùng lưu trữ cho user 'huy'...");

    // Tạo thư mục /home/huy
    let home_dir = "/home/huy";
    if let Err(e) = std::fs::create_dir_all(home_dir) {
        eprintln!("[init] Lỗi tạo thư mục {}: {}", home_dir, e);
        return;
    }

    // Đặt quyền sở hữu /home/huy cho user huy (UID 1000, GID 1000)
    use std::os::unix::fs::chown;
    if let Err(e) = chown(home_dir, Some(1000), Some(1000)) {
        eprintln!("[init] Lỗi chown {} cho user huy: {}", home_dir, e);
    }

    // Xác định phân vùng cần mount
    let mut device_to_mount = None;

    // 1. Quét từ kernel cmdline
    if let Some(cmdline_part) = parse_cmdline() {
        println!("[init] Phát hiện tham số data_part từ kernel command line: {}", cmdline_part);
        device_to_mount = Some(cmdline_part);
    } 
    // 2. Fallback sang /dev/vda nếu chạy trong QEMU
    else if std::path::Path::new("/dev/vda").exists() {
        println!("[init] Không có tham số data_part, phát hiện card đĩa ảo /dev/vda (QEMU). Tự động sử dụng.");
        device_to_mount = Some("/dev/vda".to_string());
    }

    if let Some(device) = device_to_mount {
        println!("[init] Đang mount {} vào {}...", device, home_dir);
        
        // Vòng lặp chờ thiết bị lưu trữ sẵn sàng (hỗ trợ NVMe/PCIe scan trễ)
        let device_path = std::path::Path::new(&device);
        let mut attempts = 0;
        while !device_path.exists() && attempts < 20 {
            println!("[init] Thiết bị {} chưa sẵn sàng, đang đợi... (lần {})", device, attempts + 1);
            std::thread::sleep(std::time::Duration::from_millis(500));
            attempts += 1;
        }

        if !device_path.exists() {
            eprintln!("[init] Cảnh báo: Thiết bị {} không xuất hiện sau 10 giây chờ đợi.", device);
        }

        match mount_fs(&device, home_dir, "ext4", 0) {
            Ok(_) => {
                println!("[init] Đã mount thành công {} vào {}", device, home_dir);
                // Đặt lại quyền sở hữu thư mục home và nội dung bên trong cho user huy
                if let Err(e) = chown(home_dir, Some(1000), Some(1000)) {
                    eprintln!("[init] Lỗi chown {} sau khi mount: {}", home_dir, e);
                }
                
                // Tạo file chào mừng mẫu
                let welcome_file = format!("{}/welcome.txt", home_dir);
                if let Err(e) = std::fs::write(&welcome_file, "Chào mừng bạn đến với Rust-only User Space OS!\nFile này nằm trên phân vùng ext4 lưu trữ bền vững.\n") {
                    eprintln!("[init] Không thể tạo file welcome.txt: {}", e);
                } else {
                    let _ = chown(&welcome_file, Some(1000), Some(1000));
                    unsafe { libc::sync(); }
                    println!("[init] Đã tạo và đồng bộ file welcome.txt thành công.");
                }
            }
            Err(e) => {
                eprintln!("[init] Cảnh báo: Không thể mount {} vào {}: {}", device, home_dir, e);
            }
        }
    } else {
        println!("[init] Không tìm thấy phân vùng lưu trữ ext4 phù hợp. Bỏ qua mount.");
    }
}

fn load_gpu_module() {
    let modules = [
        // Storage drivers (nạp trước để nhận diện ổ cứng nhanh nhất)
        "vmd", // Cần nạp VMD trước để nhận diện SSD NVMe nằm sau controller Intel VMD
        "nvme",
        "ahci",
        "sdhci",
        "sdhci-pci",
        // Input drivers
        "psmouse",
        "usbhid",
        "hid-generic",
        "i2c-hid-acpi",
        "hid-multitouch",
        "intel-lpss-pci",
        "intel-lpss-acpi",
        "i2c-designware-pci",
        // GPU drivers
        "virtio-gpu",
        "i915",
        "xe",
        "amdgpu",
        "nouveau",
    ];
    for module in &modules {
        println!("[init] Đang nạp module driver {}...", module);
        match Command::new("/bin/modprobe").arg(module).status() {
            Ok(status) if status.success() => {
                println!("[init] Đã nạp thành công module {}.", module);
            }
            Ok(status) => {
                println!("[init] Bỏ qua module {} (status {}).", module, status);
            }
            Err(e) => {
                eprintln!("[init] Không thể khởi chạy /bin/modprobe cho module {}: {}", module, e);
            }
        }
    }
    // Đợi 2 giây để udev/kernel tạo các node thiết bị trong /dev/dri/ và /dev/input/
    println!("[init] Đang đợi thiết bị đồ họa và nhập liệu sẵn sàng...");
    std::thread::sleep(std::time::Duration::from_secs(2));

    println!("[init] --- Danh sách các thiết bị đầu vào trong /dev/input ---");
    if let Ok(entries) = std::fs::read_dir("/dev/input") {
        for entry in entries.flatten() {
            println!("[init]   - {:?}", entry.path());
        }
    } else {
        println!("[init]   Thư mục /dev/input không tồn tại hoặc rỗng!");
    }

    println!("[init] --- Danh sách thiết bị đầu vào từ kernel (/proc/bus/input/devices) ---");
    if let Ok(content) = std::fs::read_to_string("/proc/bus/input/devices") {
        for line in content.lines() {
            if line.starts_with("I:") || line.starts_with("N:") || line.starts_with("H:") {
                println!("[init]   {}", line);
            }
        }
    } else {
        println!("[init]   Không thể đọc /proc/bus/input/devices");
    }
}

fn main() {
    println!("[init] Tiến trình khởi động bắt đầu (PID 1)...");
    
    // Thiết lập các hệ thống file ảo
    setup_mounts();

    // Nạp driver đồ họa cho card ảo
    load_gpu_module();

    // Khởi chạy udev daemon để quản lý nóng thiết bị đầu vào (chuột, bàn phím, touchpad)
    println!("[init] Khởi chạy udev daemon...");
    match Command::new("/lib/systemd/systemd-udevd").arg("--daemon").status() {
        Ok(status) if status.success() => {
            println!("[init] Đã khởi chạy systemd-udevd dưới dạng daemon.");
            // Phát sự kiện add để udev quét và nhận diện các thiết bị đã kết nối sẵn
            let _ = Command::new("/bin/udevadm").args(&["trigger", "--action=add"]).status();
            // Đợi udev xử lý xong toàn bộ các sự kiện quét thiết bị
            let _ = Command::new("/bin/udevadm").arg("settle").status();
            println!("[init] udevadm đã quét và cấu hình xong các thiết bị.");
        }
        Ok(status) => {
            eprintln!("[init] Cảnh báo: systemd-udevd khởi chạy thất bại với status: {}", status);
        }
        Err(e) => {
            eprintln!("[init] Lỗi khởi chạy udev daemon: {}", e);
        }
    }

    // Thiết lập thư mục và mount phân vùng dữ liệu cho user huy
    setup_user_storage();

    // Thiết lập PATH và các biến môi trường cơ bản
    unsafe {
        std::env::set_var("PATH", "/bin:/sbin:/usr/bin:/usr/sbin");
        std::env::set_var("HOME", "/root");
        std::env::set_var("TERM", "xterm");
    }

    // Khởi chạy Anvil Compositor
    start_anvil();

    // Khởi chạy các dịch vụ giao diện (app-manager, rust-dock, test client)
    start_desktop_services();

    // Khởi chạy CLI shell tương tác dự phòng trên console serial
    run_shell();
}
