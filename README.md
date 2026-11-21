# MT Layout Tools

Plugin SketchUp 2022 (Windows) dàn trang bản vẽ nội thất cho MT Design.

## Cài lần đầu
1. Tải `dist/mt_layout_tools.rbz`.
2. SketchUp → **Extensions → Extension Manager → Install Extension** → chọn file `.rbz`.

## Cập nhật
Menu **Extensions → MT Layout Tools → Cập nhật** (hoặc nút trên thanh công cụ MT Layout Tools).
Plugin đọc `version.json` ở nhánh `main`, nếu có bản mới thì tải `dist/mt_layout_tools.rbz`, kiểm SHA-256 và cài đè.
Khi mở SketchUp, plugin cũng tự kiểm tra tối đa 1 lần/ngày.

## Triển khai chi tiết A3 (v1.2)
Chọn 1 tủ/Group → bảng MT → **Triển khai chi tiết A3** → điền khung tên → **Xuất PDF A3**.
- Hình chiếu: Mặt đứng, Mặt đứng tháo cánh (ẩn Tag cánh), Bên trái, Bên phải, Mặt sau, Mặt bằng, Trục đo.
- Kích thước tổng + kích thước chuỗi (tự dò vách/kệ, có độ dày ván), tỉ lệ tự chọn, tô màu vật liệu, bảng MAT-xx, khung tên.

## Cấu trúc
```
src/mt_layout_tools.rb            # loader (đăng ký extension)
src/mt_layout_tools/version.rb    # số phiên bản
src/mt_layout_tools/main.rb       # menu, toolbar
src/mt_layout_tools/updater.rb    # cơ chế cập nhật
src/mt_layout_tools/detail/       # triển khai chi tiết A3 (geometry, sheet, pdf, ui)
src/mt_layout_tools/icons/
dist/mt_layout_tools.rbz          # gói cài đặt (do tools/build_rbz.py tạo)
version.json                      # phiên bản mới nhất + link .rbz + SHA-256
```

## Phát hành bản mới
1. Sửa code trong `src/`, tăng `VERSION` trong `version.rb`.
2. `python3 tools/build_rbz.py "Ghi chú thay đổi"`.
3. Commit `src/`, `dist/`, `version.json` và push lên `main`.
