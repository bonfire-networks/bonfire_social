defmodule Bonfire.Social.MarkersTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Markers

  test "web feed resume ignores stale positions without deleting the marker" do
    user = fake_user!()
    cursor = Needle.ULID.generate()

    assert {:ok, _marker} = Markers.save_reading_position(user, "my", cursor)

    backdate_markers(4)

    refute Markers.get_resumable_reading_position(user, "my")
    assert Markers.get_reading_position(user, "my") == cursor

    backdate_markers(1)

    assert Markers.get_resumable_reading_position(user, "my") == cursor
  end

  defp backdate_markers(days_ago) do
    Bonfire.Common.Repo.update_all(Bonfire.Social.Marker,
      set: [updated_at: Bonfire.Common.DatesTimes.past(days_ago, :day)]
    )
  end
end
