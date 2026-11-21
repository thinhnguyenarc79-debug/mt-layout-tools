# encoding: UTF-8
# SketchUp 2022 chạy Ruby 2.7: chặn cú pháp / hàm chỉ có từ Ruby 3.x (lỗi thật ở v2.7.0:
# "def x(a) = ..." làm hidden_fill.rb không nạp được -> "uninitialized constant ...HiddenFill").
require_relative 'test_helper'

class TestRuby27Compat < Minitest::Test
  SRC = Dir[File.expand_path('../src/**/*.rb', __dir__)]

  RULES = {
    'def một dòng "def x = ..." (Ruby 3.0)' => /^\s*def\s+[\w.?!]+(?:\s+=\s|\([^)]*\)\s*=\s)/,
    'Hash#except (Ruby 3.0)' => /\.except\(/,
    'Array#intersect? (Ruby 3.1)' => /\.intersect\?/,
    'Integer#ceildiv / Data.define (Ruby 3.2)' => /ceildiv|Data\.define/,
    'gọi hàm rút gọn "f(x:)" (Ruby 3.1)' => /\w\([^()"']*\b[a-z_]+:\s*[,)]/,
    'chuyển tiếp ẩn danh "f(*)" / "f(&)" (Ruby 3.2)' => /\w\((\*|\*\*|&)\)/,
    'tham số "it" (Ruby 3.4)' => /\{\s*it[\.\s\]]/,
    'gán phải "expr => x" (Ruby 3.0)' => /\)\s*=>\s*[a-z_]+\s*$/
  }.freeze

  def test_khong_dung_cu_phap_ruby3
    refute_empty SRC
    bad = []
    SRC.each do |f|
      File.readlines(f, encoding: 'UTF-8').each_with_index do |ln, i|
        next if ln.strip.start_with?('#')

        RULES.each do |name, re|
          next unless ln =~ re
          next if name.start_with?('chuyển tiếp') && ln =~ /^\s*def /

          bad << "#{File.basename(f)}:#{i + 1} #{name}: #{ln.strip}"
        end
      end
    end
    assert_empty bad, "Không chạy được trên SketchUp 2022 (Ruby 2.7):\n#{bad.join("\n")}"
  end
end
