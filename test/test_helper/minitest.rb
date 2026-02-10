class Minitest::Test
  def teardown
    Clickhouse.instance_variables.each do |name|
      Clickhouse.instance_variable_set name, nil
    end
  end
end

class Minitest::Spec
  def assert_query(expected, actual)
    assert_equal(expected.strip.gsub(/^\s+/, ""), actual)
  end
end
