defmodule Bonfire.Social.PostContentsTagsDisabledTest do
  @moduledoc """
  With the tags extension off, post content skips tag processing but is still sanitised: titles, content warnings and bodies are shown with `rich/1`, which outputs a string starting with `<` as HTML as stored.
  """
  use Bonfire.Social.DataCase, async: false

  alias Bonfire.Common.Config
  alias Bonfire.Common.Extend
  alias Bonfire.Social.PostContents

  @moduletag :backend

  setup do
    Config.put([Bonfire.Social.Tags, :modularity], :disabled, :bonfire_social)
    Extend.clear_modularity_cache()

    on_exit(fn ->
      Config.put([Bonfire.Social.Tags, :modularity], Bonfire.Social.Tags, :bonfire_social)
      Extend.clear_modularity_cache()
    end)

    %{user: fake_user!()}
  end

  test "control: the extension is off", %{user: user} do
    refute Extend.module_enabled?(Bonfire.Social.Tags, user)
  end

  for field <- [:name, :summary, :html_body] do
    test "typed markup is removed (#{field})", %{user: user} do
      assert %{unquote(field) => value} =
               PostContents.maybe_prepare_contents(
                 %{unquote(field) => "<script>alert(1)</script><b onmouseover=alert(2)>Safe</b>"},
                 user,
                 nil,
                 []
               )

      refute value =~ ~r/<script|onmouseover/i
      assert value =~ "Safe"
    end

    test "entity-encoded markup is removed (#{field})", %{user: user} do
      assert %{unquote(field) => value} =
               PostContents.maybe_prepare_contents(
                 %{unquote(field) => "&lt;script&gt;alert(1)&lt;/script&gt; Safe"},
                 user,
                 nil,
                 []
               )

      refute value =~ ~r/script/i
      assert value =~ "Safe"
    end
  end
end
