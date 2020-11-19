defmodule BonfireSocialTest do
  use ExUnit.Case
  doctest BonfireSocial

  test "greets the world" do
    assert BonfireSocial.hello() == :world
  end
end
