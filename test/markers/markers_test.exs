defmodule Bonfire.Social.MarkersTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Markers

  test "web feed resume ignores stale positions without deleting the marker" do
    user = fake_user!()
    cursor = Needle.ULID.generate()

    assert {:ok, _marker} = Markers.save_reading_position(user, "my", cursor)

    backdate_markers(31, :minute)

    refute Markers.get_resumable_reading_position(user, "my")
    assert Markers.get_reading_position(user, "my") == cursor

    backdate_markers(29, :minute)

    assert Markers.get_resumable_reading_position(user, "my") == cursor
  end

  test "reconfirming an unchanged marker refreshes the resume window" do
    user = fake_user!()
    cursor = Needle.ULID.generate()

    assert {:ok, _marker} = Markers.save_reading_position(user, "my", cursor)
    backdate_markers(31, :minute)

    assert {:ok, _marker} = Markers.save_reading_position(user, "my", cursor)
    assert Markers.get_resumable_reading_position(user, "my") == cursor
  end

  test "regression for issue #2220: Markers.save with a user whose account isn't preloaded is FLAGGED (raises) — its caller must preload the account" do
    # Seen is per-account, so `normalize_subject!` raises in test env on any subject reaching Seen
    # without a preloaded account — a detector forcing the caller's initial query to preload it (in
    # prod it's rescued + logged so the ACCOUNT is still the subject). A bare user is what
    # `Users.by_account!` / the Masto token-auth produce. The real Bearer markers path (which proloads
    # the account) is covered green in `masto_markers_api_test.exs`.
    account = fake_account!()
    alice = fake_user!(account)
    poster = fake_user!()
    {:ok, _} = Bonfire.Social.Graph.Follows.follow(alice, poster)
    post = Bonfire.Posts.Fake.fake_post!(poster, "public")

    alice_bare = Bonfire.Common.Repo.get!(Bonfire.Data.Identity.User, alice.id)
    refute Bonfire.Common.Utils.current_account(alice_bare)

    assert_raise RuntimeError, ~r/preload the account/, fn ->
      Markers.save(alice_bare, "home", post.id)
    end
  end

  defp backdate_markers(amount, unit) do
    Bonfire.Common.Repo.update_all(Bonfire.Social.Marker,
      set: [updated_at: Bonfire.Common.DatesTimes.past(amount, unit)]
    )
  end
end
