# MT Layout Tools

Plugin SketchUp 2022 (Windows) dàn trang bản vẽ nội thất cho MT Design.

## Cài lần đầu
1. Tải `dist/mt_layout_tools.rbz`.
2. SketchUp → **Extensions → Extension Manager → Install Extension** → chọn file `.rbz`.

## Cập nhật
Menu **Extensions → MT Layout Tools → Cập nhật** (hoặc nút trên thanh công cụ MT Layout Tools).
Plugin đọc `version.json` ở nhánh `main`, nếu có bản mới thì tải `dist/mt_layout_tools.rbz`, kiểm SHA-256 và cài đè.
Khi mở SketchUp, plugin cũng tự kiểm tra tối đa 1 lần/ngày.

## Cấu trúc
```
src/mt_layout_tools.rb            # loader (đăng ký extension)
src/mt_layout_tools/version.rb    # số phiên bản
src/mt_layout_tools/main.rb       # menu, toolbar
src/mt_layout_tools/updater.rb    # cơ chế cập nhật
src/mt_layout_tools/icons/
dist/mt_layout_tools.rbz          # gói cài đặt (do tools/build_rbz.py tạo)
version.json                      # phiên bản mới nhất + link .rbz + SHA-256
```

## Phát hành bản mới
1. Sửa code trong `src/`, tăng `VERSION` trong `version.rb`.
2. `python3 tools/build_rbz.py "Ghi chú thay đổi"`.
3. Commit `src/`, `dist/`, `version.json` và push lên `main`.
