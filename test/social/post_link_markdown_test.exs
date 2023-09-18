defmodule Bonfire.Social.PostLinkMarkdownTest do
  use Bonfire.Social.DataCase, async: false
  use Bonfire.Common.Utils
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  use Bonfire.Common.Utils
  import Tesla.Mock

  setup_all do
    mock_global(fn
      %{method: :get, url: "https://developer.mozilla.org/en-US/docs/Web/API/"} ->
        %Tesla.Env{status: 200, body: "<title>Web API</title>"}

      %{method: :get} ->
        %Tesla.Env{status: 200, body: "{}"}
    end)

    :ok
  end

  test "link detection works" do
    user = Fake.fake_user!()

    post =
      fake_post!(user, "public", %{
        post_content: %{
          html_body: "epic html with a link https://developer.mozilla.org/en-US/docs/Web/API/"
        }
      })

    assert post.post_content.html_body ==
             "epic html with a link [developer.mozilla.org/en-US/...](https://developer.mozilla.org/en-US/docs/Web/API/)"

    post =
      fake_post!(user, "public", %{
        post_content: %{
          html_body: "[epic html with a link](https://developer.mozilla.org/en-US/docs/Web/API/]"
        }
      })

    assert post.post_content.html_body ==
             "[epic html with a link](https://developer.mozilla.org/en-US/docs/Web/API/]"

    post =
      fake_post!(user, "public", %{
        post_content: %{
          html_body: "https://developer.mozilla.org/en-US/docs/Web/API/ epic html with a link"
        }
      })

    assert post.post_content.html_body ==
             "[developer.mozilla.org/en-US/...](https://developer.mozilla.org/en-US/docs/Web/API/) epic html with a link"

    post =
      fake_post!(user, "public", %{
        post_content: %{
          html_body: "https://developer.mozilla.org/en-US/docs/Web/API/\nepic html with a link"
        }
      })

    assert post.post_content.html_body =~
             "[developer.mozilla.org/en-US/...](https://developer.mozilla.org/en-US/docs/Web/API/)"

    post =
      fake_post!(user, "public", %{
        post_content: %{
          html_body: "https://developer.mozilla.org/en-US/docs/Web/API/"
        }
      })

    assert post.post_content.html_body ==
             "[developer.mozilla.org/en-US/...](https://developer.mozilla.org/en-US/docs/Web/API/)"

    post =
      fake_post!(user, "public", %{
        post_content: %{
          html_body: "epic html with a link\n\nhttps://developer.mozilla.org/en-US/docs/Web/API/"
        }
      })

    assert post.post_content.html_body =~
             "[developer.mozilla.org/en-US/...](https://developer.mozilla.org/en-US/docs/Web/API/)"
  end
end
