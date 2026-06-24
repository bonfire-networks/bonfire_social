if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.PostMediaTest do
    use Bonfire.Social.DataCase, async: false

    import Bonfire.Common.E
    import Bonfire.Files.Simulation

    alias Bonfire.API.GraphQL.Schema
    alias Bonfire.Files
    alias Bonfire.Files.ImageUploader

    @moduletag :graphql

    @create_post """
    mutation($content: PostContentInput!, $mediaIds: [ID]) {
      create_post(post_content: $content, uploaded_media: $mediaIds, boundary: "public") {
        id
      }
    }
    """

    setup do
      account = fake_account!()
      me = fake_user!(account)
      other = fake_user!(fake_account!())
      {:ok, me: me, other: other}
    end

    test "create_post attaches media uploaded by the current user", %{me: me} do
      assert {:ok, media} = Files.upload(ImageUploader, me, image_file(), %{})

      {:ok, result} =
        Absinthe.run(@create_post, Schema,
          variables: %{
            "content" => %{"html_body" => "<p>Post with GraphQL media</p>"},
            "mediaIds" => [media.id]
          },
          context: Schema.context(%{current_user: me})
        )

      refute result[:errors]
      post_id = get_in(result, [:data, "create_post", "id"])
      assert is_binary(post_id) and post_id != ""

      attached_media_ids =
        post_id
        |> Bonfire.Common.Needles.get!(current_user: me, skip_boundary_check: true)
        |> repo().maybe_preload(:media)
        |> e(:media, [])
        |> Enum.map(&e(&1, :id, nil))

      assert media.id in attached_media_ids
    end

    test "create_post rejects another user's uploaded media", %{me: me, other: other} do
      assert {:ok, media} = Files.upload(ImageUploader, other, image_file(), %{})

      {:ok, result} =
        Absinthe.run(@create_post, Schema,
          variables: %{
            "content" => %{"html_body" => "<p>Not my media</p>"},
            "mediaIds" => [media.id]
          },
          context: Schema.context(%{current_user: me})
        )

      assert result[:errors]
      assert get_in(result, [:data, "create_post"]) == nil
    end
  end
end
