defmodule GiuliaTest do
  use ExUnit.Case

  test "version is available" do
    assert {:ok, version} = :application.get_key(:giulia, :vsn)
    assert is_list(version)
  end
end
