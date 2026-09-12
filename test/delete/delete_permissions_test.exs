defmodule Bonfire.Social.DeletePermissionsTest do
  use Bonfire.Social.DataCase, async: false

  alias Bonfire.Common.Config
  alias Bonfire.Common.Needles
  alias Bonfire.Data.Social.Created
  alias Bonfire.Me.{Accounts, Fake, Users}
  alias Bonfire.Posts
  alias Bonfire.Social.Objects

  @moduletag capture_log: true

  setup do
    Process.put([:bonfire, :skip_all_boundary_checks], false)
    refute Config.get(:skip_all_boundary_checks)

    owner = Fake.fake_user!()
    other = Fake.fake_user!()
    refute Accounts.is_admin?(owner)
    refute Accounts.is_admin?(other)

    {:ok, post} =
      Posts.publish(
        current_user: owner,
        post_attrs: %{post_content: %{html_body: "Delete permissions #{Faker.UUID.v4()}"}},
        boundary: "public"
      )

    {:ok, owner: owner, other: other, post: post}
  end

  test "a non-admin cannot delete another user's public post by ID", context do
    result = Objects.delete(context.post.id, current_user: context.other)

    assert {result, Posts.count_for_user(context.owner)} == {{:error, :not_found}, 1}
    assert {:ok, _} = Posts.read(context.post.id, current_user: context.owner)
  end

  test "an anonymous caller cannot delete a public post by ID", context do
    result = Objects.delete(context.post.id, current_user: nil)

    assert {result, Posts.count_for_user(context.owner)} == {{:error, :not_found}, 1}
    assert {:ok, _} = Posts.read(context.post.id, current_user: context.owner)
  end

  test "the owner can delete a post by ID", context do
    assert {:ok, _} = Objects.delete(context.post.id, current_user: context.owner)
    assert {:error, _} = Posts.read(context.post.id, current_user: context.owner)
  end

  test "an administrator can delete another user's post by ID", context do
    {:ok, admin} = Users.make_admin(context.other)
    assert Accounts.is_admin?(admin)

    assert {:ok, _} = Objects.delete(context.post.id, current_user: admin)
    assert {:error, _} = Posts.read(context.post.id, current_user: context.owner)
  end

  test "generic queries enforce delete permission for non-admins", context do
    query =
      Needles.query(Created, [id: context.post.id],
        current_user: context.other,
        verbs: [:delete],
        skip_boundary_check: :admins
      )

    assert [] = repo().all(query)
  end

  test "generic queries retain the administrator exception", context do
    {:ok, admin} = Users.make_admin(context.other)
    assert Accounts.is_admin?(admin)

    query =
      Needles.query(Created, [id: context.post.id],
        current_user: admin,
        verbs: [:delete],
        skip_boundary_check: :admins
      )

    assert [%{id: id}] = repo().all(query)
    assert id == context.post.id
  end
end
