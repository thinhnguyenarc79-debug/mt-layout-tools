# MT Layout Tools – AUTO LAYOUT PRO

Plugin SketchUp (2021–2026, Windows) tự động triển khai bản vẽ nội thất cho MT Design: chọn model → tự dựng hình chiếu có khử nét khuất, ghi kích thước đo từ hình học thật, dàn lên khổ giấy có khung tên, xuất PDF/SVG.

## 1. Cài đặt
- **Lần đầu:** tải `dist/mt_layout_tools.rbz` → SketchUp → **Extensions → Extension Manager → Install Extension** → chọn file → khởi động lại SketchUp.
- **Cập nhật:** bấm biểu tượng **MT** trên thanh công cụ → **Cập nhật** (đọc `version.json` qua GitHub API, kiểm SHA-256, cài đè, không phải cài lại).

## 2. Sử dụng (Giai đoạn 1)
1. Bấm biểu tượng **MT** → **AUTO LAYOUT PRO**.
2. Cột trái:
   - **1. Dự án:** tên, khổ giấy (A4–A0), mở/lưu `.json`.
   - **2. Danh sách model:** CHỈ các Group/Component bạn đang chọn trong SketchUp (chọn trước khi mở, hoặc chọn rồi bấm **⤓ Lấy đối tượng đang chọn**). Group/Component con bên trong được phân tích như bộ phận của Group cha, không tách thành model riêng. Mỗi dòng: tick, tên, Rộng × Cao × Sâu (mm), nút 👁 chọn/phóng tới đối tượng. Tick model → **▶ Tự động triển khai** (mỗi model 1 tờ). Không chọn gì → plugin báo, không tự lấy model khác.
   - **3. Tag SketchUp:** bỏ tick Tag để loại khỏi bản vẽ (không đổi model); chọn **Tag cánh** cho "Mặt đứng tháo cánh".
   - **4. Dàn trang tự động:** hình chiếu mặc định, tỉ lệ, hướng mặt trước, gộp khoảng nhỏ, làm tròn DIM, tô màu.
   - **5. Trang giấy:** chọn/sắp xếp/xoá/đổi tên (bấm đúp). Trang cũ của bộ phận con (đã bị gộp vào Group cha) hoặc của đối tượng đã xoá được đánh dấu ⚠; nút **🧹 Dọn trang lỗi** xoá chúng sau khi bạn xác nhận. Triển khai lại cùng model không tạo trùng (tuỳ chọn *Thay thế trang cũ*).
   - **6. Khung tên.**
3. Giữa: tờ giấy vector. Lăn chuột = zoom, chuột giữa / phím Space / công cụ ✋ = kéo màn hình, **bấm + kéo hình chiếu** để dời (phím mũi tên dời 1 mm, Shift = 10 mm), `F` vừa khung, `Ctrl+Z / Ctrl+Y`.
4. Phải: thuộc tính trang (tên, ký hiệu, tỉ lệ, hướng mặt trước, hình chiếu, DIM) và hình chiếu đang chọn.
5. **⟳ Cập nhật bản vẽ** sau khi sửa model; **💾 Lưu** ghi dự án vào file SKP (Ctrl+S trong SketchUp để lưu file); **PDF trang / PDF tất cả / SVG** để xuất.

## 3. Cấu trúc
```
src/mt_layout_tools.rb                    loader
src/mt_layout_tools/main.rb               menu, thanh công cụ, dọn thư mục cũ
src/mt_layout_tools/panel.rb, ui/         bảng MT (biểu tượng) + nút Cập nhật
src/mt_layout_tools/updater.rb            cập nhật qua GitHub
src/mt_layout_tools/auto_layout/
  auto_layout.rb                          controller HtmlDialog (callbacks, cache, xuất file, log)
  core/model_scanner.rb                   liệt kê model, Tag, tìm theo persistent_id
  core/geometry.rb                        hệ toạ độ cục bộ, hướng mặt trước, lọc Tag, phép chiếu, khử nét khuất
  core/dimension_engine.rb                DIM tổng + DIM chuỗi đo từ hình học
  core/sheet.rb                           dàn trang, tự chọn tỉ lệ, bảng vật liệu, khung tên
  core/canvas.rb                          vẽ chung PDF/SVG
  core/pdf.rb                             ghi PDF vector nhiều trang, font tiếng Việt nhúng
  core/project_store.rb                   dự án (lưu trong SKP / .json), làm sạch dữ liệu
  ui/index.html, app.css, app.js          giao diện biên tập
  fonts/                                  Noto Sans (OFL)
tests/                                    test chạy ngoài SketchUp
tools/build_rbz.py                        đóng gói + version.json
```

## 4. Tính năng
| Hạng mục | Trạng thái |
|---|---|
| RBZ cài được, nút Cập nhật | ✅ |
| Đọc model thật: Group/Component lồng nhau, transformation tích luỹ, xoay bất kỳ, ẩn/Tag ẩn, đơn vị → mm | ✅ |
| Danh sách model chỉ từ selection + Tag, lọc Tag | ✅ |
| Hướng mặt trước (-Y/+Y/-X/+X) | ✅ |
| Mặt đứng trước/sau/trái/phải, mặt bằng, mặt đáy, trục đo | ✅ |
| Khử nét khuất | ✅ (đường khuất bị bỏ, chưa vẽ nét đứt) |
| DIM tổng + DIM chuỗi theo vách/kệ (đo thật, gộp khoảng nhỏ, làm tròn) | ✅ |
| Mặt đứng tháo cánh (theo Tag cánh) | ✅ |
| Tự chọn tỉ lệ, xếp nhiều hàng, kẹp không đè khung tên | ✅ |
| Editor: zoom/pan, chọn & kéo hình chiếu, undo/redo, nhiều trang | ✅ |
| Lưu dự án (SKP / JSON), xuất PDF nhiều trang, SVG | ✅ |
| Mặt cắt thật A-A/B-B/C-C (giao mặt phẳng × hình học, nét cắt, hatch, DIM, ký hiệu + mũi tên, đề xuất vị trí, kéo đường cắt) | ✅ v2.2 |
| Chú thích: Text, nhiều dòng, Leader, ghi chú vật liệu (chọn từ vật liệu có trong model), layer ẩn/hiện | ✅ v2.3 |
| Chi tiết phóng to (khoanh vùng trên hình chiếu/mặt cắt, tỉ lệ riêng, DIM, hatch) | ✅ v2.3 |
| Phân biệt DIM có cánh / tháo cánh: nhận diện cánh (chọn tay theo đường dẫn instance, thuộc tính, Tag, tên); bộ DIM Exterior/Door/Interior/Section; chống chồng chữ; kéo hàng DIM | ✅ v2.4 |
| Giữ đúng tỉ lệ đã chọn: tự chia nhiều tờ; mỗi tờ là 1 dòng ở TRANG GIẤY với mã riêng A-01, A-02…, nút Tờ trước/Tờ sau, PDF tờ / PDF tất cả | ✅ v2.4.1 |
| Nhận diện cấu tạo tủ (gán tay > thuộc tính > Tag > tên > vật liệu kính > hình học-đề xuất); mục CẤU TẠO TỦ: đếm, gán vai trò, tô sáng bộ phận; DIM tháo cánh theo vách/đợt; chữ DIM né ký hiệu/chú thích; kéo từng số DIM; chuyển DIM chi tiết khi quá dày | ✅ v2.5.0 |
| Tỉ lệ riêng từng hình (chuột phải: 1:5…1:100, tùy chỉnh, theo tỉ lệ trang), khóa tỉ lệ / khóa vị trí (biểu tượng khóa chỉ hiện khi biên tập), hình không vừa chuyển tờ – không thu nhỏ, báo xung đột; ký hiệu hướng mở cánh do người dùng chọn (mở trái/phải, đôi, lật lên/xuống, lùa, ngăn kéo; chỉnh nét/màu/kiểu) | ✅ v2.6.0 |
| Sửa lỗi tam giác đè trong phối cảnh trục đo: tô mặt có che khuất chính xác bằng cây BSP (đúng cả khi mặt giao cắt, model xoay, mirror/mặt đảo); chế độ trục đo: tô màu vật liệu / đơn sắc / không tô + nét khuất. Quản lý cấu tạo theo model: nhóm theo loại thu gọn được, lọc, tick nhiều mục để gán hàng loạt, xác nhận cả nhóm, danh sách ảo cho hàng nghìn bộ phận; triển khai lại không ghi đè gán tay | ✅ v2.7.0 |
| Vị trí thủ công / khóa vị trí lưu bằng toạ độ mm tuyệt đối + tờ chứa hình (không bị mất khi chuyển tờ, đổi tỉ lệ, cập nhật, triển khai lại, đóng/mở cửa sổ); báo tràn giấy / chồng hình. Nhận diện cấu tạo tổng quát theo hình học (OBB, tiếp xúc, dãy cánh, tay nắm, cánh lọt lòng, cánh lùa, ngăn kéo) cho mọi kiểu tủ/bếp xoay góc bất kỳ – kết quả là đề xuất có độ tin cậy, chỉ cánh đã xác nhận mới dùng cho DIM/tháo cánh; nút QUÉT VÀ NHẬN DIỆN CẤU TẠO, tô sáng nhiều bộ phận, xác nhận hàng loạt, lọc theo cụm tủ | ✅ v2.8.0 |
| Lưu dự án (kiểm tra đọc lại, báo rõ khi file SKP chưa lưu) / Xuất bản sao .json có schema / Mở dự án; bản nháp tự động an toàn (ghi tạm + đổi tên) và hỏi khôi phục sau khi tắt đột ngột; THÊM MODEL theo giao dịch – chỉ ghép tờ mới vào cuối, trang cũ giữ nguyên 100%; model trùng hỏi Cập nhật/Bỏ qua; bố cục đã chốt cho mọi hình (Tự động / Đã chỉnh tay / Đã khóa) – chỉ Dàn trang lại (chọn phạm vi, cảnh báo, ↶) mới đổi | ✅ v2.9.0 |
| Menu chuột phải: trên hình (đổi tỷ lệ, khóa, cập nhật, chuyển / tạo bản sao sang trang khác, bản sao tại trang này, sao chép–dán, tạo chi tiết, xóa) và trên giấy trống (thêm hình chiếu vào trang này – chọn CHUYỂN hoặc TẠO BẢN SAO, dán, tạo chi tiết, bố trí lại trang, đề xuất lấp khoảng trống); chi tiết nằm ngay tờ trích (đặt vào chỗ trống, không đủ chỗ thì hỏi), kiểu marker chữ nhật / tròn / elip nét đứt, mũi tên, bóng số, đổi tên–tỷ lệ–vùng trích | ✅ v2.10.0 |
| Tôn trọng thao tác tay: vùng trích chi tiết tính đúng toạ độ (zoom/pan), hình nguồn theo vùng vẽ chứa điểm bấm, cắt tròn/elip thật (SVG + PDF), chỉnh vùng trích bằng điểm điều khiển, chi tiết tô màu hoặc nét đơn sắc; đổi tỉ lệ chỉ hình đó, giữ điểm neo, bố cục đã chốt không tự đổi tỉ lệ, xung đột hỏi 4 lựa chọn; thêm hình có chọn tỉ lệ + xem trước vị trí; gán bộ phận ngay trên bản vẽ 2D (ứng viên trước → sau) | ✅ v2.11.0 |
| CHI TIẾT CẤU TẠO: mặt cắt thật qua hình học 3D tại đường cắt trong vùng gọi (đứng/ngang, đảo hướng nhìn, giới hạn độ sâu thể hiện), xén đúng vùng, nét cắt đậm, hatch theo vật liệu có trong model (gỗ 45°, kim loại/đá lưới, kính để trống), DIM, chú thích vật liệu tự động; marker có đường cắt gạch chấm + mũi tên; độ dày nét in theo mm | ✅ v2.12.0 |
| Ký hiệu cánh mở nhìn từ trên: gán trên mặt đứng 1 lần -> mặt bằng và mọi mặt cắt nhìn từ trên đi qua cánh tự vẽ lá cánh mở + cung (quay quanh trục bản lề thật theo OBB của cánh; xoay/mirror đúng; không theo tên A-A/B-B); lật lên/xuống theo trục nằm; lùa/ngăn kéo không vẽ cung; cấu hình góc mở, mở vào/ra, kiểu nét; DIM và tên hình lùi ra ngoài cung | ✅ v2.13.0 |
| DIM thủ công 2 điểm (⟷ DIM / phím M / chuột phải hình): Smart Snap vào hình học thực (đầu mút, góc ván, giao điểm, cạnh, nét cắt – bỏ qua DIM/hatch/leader/ký hiệu cánh); đo thông thủy tự về mặt trong của tấm, đo thông thủy 1 nhấp; đo dọc/ngang/thẳng; đặt bên trái mặc định, nối chuỗi/không chồng; kéo dời, kéo đổi điểm bám, ẩn/xóa, Undo/Redo; lưu theo hình, bám theo bộ phận khi cập nhật model, báo mất liên kết; không bị Auto DIM ghi đè | ✅ v2.14.0 |
| Chỉnh sửa DIM tự động & chữ (✎ DIM & Chữ / phím E): mỗi đoạn Auto DIM là 1 đối tượng có id ổn định – chọn, grip điểm đầu/cuối (Smart Snap), kéo cả chuỗi hoặc riêng đoạn (Alt / Tách khỏi chuỗi), gộp chuỗi, dời chữ, nội dung hiển thị riêng ("<>" = số đo thật), ẩn/xóa/khóa, khôi phục; chỉnh sửa lưu riêng và áp lại sau mỗi lần dựng, đoạn đã xóa không tạo lại, mất mốc thì báo; tên hình sửa/dời/cỡ/màu/căn lề/đậm/khóa, dòng tỷ lệ luôn theo tỷ lệ thật; chú thích nhấp đúp sửa tại chỗ, khóa; cảnh báo DIM chồng tên hình | ✅ v2.15.0 |
| Hiệu năng model nhiều mặt cong: zoom/pan bằng viewport transform (không dựng/vẽ lại khi zoom, chốt nét sau khi dừng), gộp mảng tô cùng màu liền nhau (ít phần tử SVG/PDF, hình y hệt), mặt cắt dùng lại cây BSP, dựng cây BSP nhanh hơn, hình học Smart Snap chỉ gửi khi cần, rê chuột/kéo grip tối đa 1 lần tính mỗi khung hình; nút ⏱ Đo hiệu năng trang này (đếm Face/Edge, thời gian từng bước, số nét, FPS zoom/pan/Snap – lưu %TEMP%\\mt_auto_layout_perf.txt) | ✅ v2.16.0 |
| Job Engine máy trạng thái (không Fiber/Thread) | ✅ v2.3.1 |
| Model lớn: cache definition, lưới không gian, 3 mức dự phòng, tiến trình + Huỷ, log | ✅ v2.1 |
| Nét đứt cho cạnh khuất, phân cấp nét bao/cấu tạo, đường trục | ⏳ Giai đoạn 2 |
| Nhận diện bộ phận tủ (cánh, vách, đợt…), gán thủ công | ⏳ Giai đoạn 2 |
| Công cụ vẽ 2D còn lại (line, rect, circle, dim tay, hatch tay) | ⏳ Giai đoạn 4 |
| DXF, PNG; DWG/LayOut (cần kiểm tra API) | ⏳ Giai đoạn 3 |
| Đồng bộ tự phát hiện thay đổi, hàng loạt có tiến trình/huỷ | ⏳ Giai đoạn 4 |

## 5. Test
```
ruby tests/run_all.rb
```
Kiểm: chỉ lấy đối tượng đang chọn (file 50 Group chọn 1; chọn 3; Group cha chứa 20 con; không chọn; chỉ tạo trang cho model được tick), kích thước Rộng×Cao×Sâu đúng trục, kích thước hình chiếu, khử nét khuất (che toàn phần/một phần), xoay mặt trước, DIM khoang không đều, DIM chuỗi, gộp & làm tròn, hình nằm trong vùng vẽ & không chồng nhau, tự đổi tỉ lệ, kẹp khi kéo, SVG hợp lệ, PDF nhiều trang đúng khổ, làm sạch dữ liệu dự án.
Phần cần kiểm trong SketchUp: đọc model thật (`model_scanner`, `Geometry.capture`), hộp thoại, lưu thuộc tính, hộp lưu file.

## 6. Sửa lỗi & nâng cấp
- Lỗi khi chạy được ghi vào `%TEMP%\mt_auto_layout.log`; Ruby Console của SketchUp cũng in lỗi.
- Phát hành bản mới: sửa `src/`, tăng `VERSION` trong `version.rb`, `python3 tools/build_rbz.py "ghi chú"`, chạy test, commit & push `main`.
