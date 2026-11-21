# encoding: UTF-8
Dir[File.join(__dir__, 'test_*.rb')].sort.each { |f| require f unless f.end_with?('test_helper.rb') }
