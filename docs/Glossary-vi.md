# Bảng thuật ngữ (Glossary)

Giải thích ngắn gọn các thuật ngữ dùng trong repo này và trong các trao đổi về nó.

## ELF

**Executable and Linkable Format** — định dạng file nhị phân thực thi/thư viện của Linux và Android.
Cả file chạy được (`ffmpeg`, `ffprobe`) lẫn thư viện chia sẻ (`libavcodec.so`) đều là ELF; khác nhau ở
loại (`ET_EXEC`/`ET_DYN`) chứ không ở phần mở rộng tên file. Trên Android, việc một file ELF có **chạy
được hay không** phụ thuộc quyền exec của thư mục chứa nó, không phụ thuộc nội dung file.

## ABI (Application Binary Interface)

Giao ước nhị phân giữa mã máy và hệ thống: kiến trúc CPU, cách truyền tham số, layout struct...
Trên Android, ABI là các tên `arm64-v8a`, `x86_64`, `armeabi-v7a`, `x86`; binary build cho ABI này
không chạy trên ABI khác. Repo này build 2 ABI: `arm64-v8a` và `x86_64`.

## RID (Runtime Identifier)

Định danh nền tảng của .NET dạng `<os>-<arch>`: `win-x64`, `linux-arm64`, `android-arm64`...
NuGet dùng RID để chọn đúng thư mục `runtimes/<rid>/native/` khi build/publish, nên gói native
phải đặt binary đúng RID thì .NET mới tự lấy ra.

## SONAME

Tên "chính thức" mà một thư viện chia sẻ ELF khai báo bên trong nó (vd `libavcodec.so.62`).
Khi thư viện A phụ thuộc thư viện B, A ghi **SONAME của B**, và trình nạp động sẽ tìm đúng tên đó.
Vì vậy file thật phải tồn tại dưới đúng tên SONAME (bản build gốc dùng symlink; symlink mất khi giải
nén trên Windows nên AutoPackager đổi tên file thật thành SONAME).

## LD_LIBRARY_PATH

Biến môi trường chỉ cho trình nạp động (`linker64` trên Android) danh sách thư mục tìm thư viện `.so`
lúc chạy. Dùng khi chạy một file thực thi mà các `.so` phụ thuộc không nằm ở đường dẫn mặc định:
`LD_LIBRARY_PATH=/duong/dan/chua/so ./ffmpeg -version`.
Nó chỉ giải quyết việc **tìm thấy thư viện**, KHÔNG cấp quyền thực thi cho file.

## nativeLibraryDir

Thư mục chứa thư viện native của một app Android sau khi cài, vd `/data/app/~~<hash>/<pkg>/lib/arm64`.
Đây là thư mục **hiếm hoi vừa nằm ngoài vùng ghi được của app vừa có quyền exec**, nên là nơi duy nhất
(không cần root) mà app có thể chạy một file nhị phân của chính nó. Truy cập trong code qua
`ApplicationInfo.NativeLibraryDir`.

## extractNativeLibs

Thuộc tính manifest `android:extractNativeLibs`. Bằng `true` thì các file trong `lib/<abi>/` của APK
được **giải nén ra đĩa** vào [nativeLibraryDir](#nativeLibraryDir) khi cài; bằng `false` (mặc định của
công cụ build hiện nay, giúp APK nhỏ hơn) thì các `.so` được nạp thẳng từ trong APK bằng mmap và
KHÔNG tồn tại như file riêng trên đĩa — khi đó không thể exec chúng như một chương trình.

## W^X (Write XOR Execute)

Nguyên tắc bảo mật "ghi được thì không chạy được, chạy được thì không ghi được". Android áp dụng từ
API 29 (Android 10) cho app: file nằm trong thư mục dữ liệu ghi được của app (`filesDir`,
`cacheDir`, thư mục ngoài...) **không được phép exec** — kể cả khi đã `chmod +x`. Đây là lý do mẹo
"copy binary vào filesDir rồi chạy" từng phổ biến nay không còn dùng được.

## P/Invoke

Cơ chế của .NET để gọi hàm trong thư viện native từ code C# (`[DllImport("avcodec")]`).
Với FFmpeg trên Android, đây là cách dùng được khuyến nghị: gọi thẳng các `.so` trong gói `Native`
thay vì chạy file thực thi `ffmpeg`.

## SELinux domain (`shell` vs `untrusted_app`)

Android gán mỗi tiến trình một "domain" SELinux quyết định nó được đọc/ghi/exec ở đâu. Hai domain hay
gặp: **`shell`** (tiến trình từ `adb shell`) được exec file trong `/data/local/tmp`; **`untrusted_app`**
(app thường do người dùng cài) thì không — app còn không đọc được `/data/local/tmp`, và bị
[W^X](#W^X-Write-XOR-Execute) chặn exec trong thư mục dữ liệu của chính nó. Vì vậy cùng một file nhị
phân có thể chạy tốt qua `adb shell` nhưng vẫn không chạy được từ trong app.
