defmodule Bonfire.Social.NotificationCategoriesTest do
  @moduledoc """
  Notification categories and the per-user preferences that filter them.

  One config list declares what a category covers and where it appears, so every reader (the
  notifications feed, its chips, the "Notify me about" switches, the Mastodon API) answers the same
  question the same way. The resolution tested here is what turns a user's switches into a feed
  filter.
  """
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Notifications
  alias Bonfire.Common.Settings
  alias Bonfire.Me.Fake

  defp declare!(categories),
    do: Process.put([:bonfire_social, Notifications, :categories], categories)

  # the returned user carries the new settings; the one passed in still holds the old ones
  defp switch_off!(me, key),
    do:
      Settings.put(Notifications.show_in_centre_key(key), false, current_user: me)
      |> current_user()

  test "categories come from config, in config order" do
    declare!(latest: %{name_pluralized: "Everything"}, like: %{name_pluralized: "Faves"})

    assert Notifications.categories() |> Keyword.keys() == [:latest, :like]
    assert Notifications.category(:like) == %{name_pluralized: "Faves"}
    assert Notifications.category(:boost) == nil
  end

  test "a category covers the activity types it declares, else the verb its key names" do
    assert Notifications.activity_types_for(:mention) == [:create]
    assert Notifications.activity_types_for(:like) == [:like]
    assert Notifications.activity_types_for(:latest) == []
  end

  test "a category's label is its own plural, else the verb's singular, else the key" do
    assert Notifications.label_for(:like) == "Likes"
    assert Notifications.label_for(:follow) == "New followers"

    declare!(bookmark: %{}, nonsense: %{})
    # from the verb registry, which only declares singulars
    assert Notifications.label_for(:bookmark) == "Bookmark"
    assert Notifications.label_for(:nonsense) == "nonsense"
  end

  test "`chip` and `row` say where a category appears" do
    declare!(
      latest: %{row: false},
      like: %{},
      other: %{row: :unimplemented}
    )

    Process.put([:bonfire, :show_unimplemented], false)

    assert Notifications.categories_shown(:chip) |> Keyword.keys() == [:latest, :like, :other]
    assert Notifications.categories_shown(:row) |> Keyword.keys() == [:like]

    # declared to show its shape, so it renders only while the instance shows unbuilt UI
    Process.put([:bonfire, :show_unimplemented], true)
    assert Notifications.categories_shown(:row) |> Keyword.keys() == [:like, :other]
    assert Notifications.implemented?(:like, :row) == true
    assert Notifications.implemented?(:other, :row) == false
  end

  test "a category is in the notifications feed unless this user switched it off" do
    me = Fake.fake_user!()

    assert Notifications.show_in_centre?(:boost, current_user: me) == true
    assert Notifications.hidden_from_centre?(:boost, current_user: me) == false

    me = switch_off!(me, :boost)

    assert Notifications.show_in_centre?(:boost, current_user: me) == false
    assert Notifications.hidden_from_centre?(:boost, current_user: me) == true
    # one category at a time
    assert Notifications.hidden_from_centre?(:like, current_user: me) == false
  end

  test "switched-off categories resolve to the feed's exclude_activity_types" do
    me = Fake.fake_user!()

    # what the `:notifications` preset means by "exclude nothing"
    assert Notifications.excluded_activity_types(current_user: me) == false

    me = switch_off!(me, :boost)
    assert Notifications.excluded_activity_types(current_user: me) == [:boost]

    # the types the category covers, not its key, so a switch hides exactly what its chip shows
    me = switch_off!(me, :mention)

    assert Notifications.excluded_activity_types(current_user: me) |> Enum.sort() ==
             [:boost, :create]
  end

  describe "exclude_hidden_types/2, the seam every reader passes through" do
    setup do
      me = Fake.fake_user!()
      {:ok, me: switch_off!(me, :boost)}
    end

    defp notifications(filters \\ %{}), do: Map.put(filters, :feed_name, :notifications)

    test "applies the preference to a notifications read", %{me: me} do
      assert Notifications.exclude_hidden_types(notifications(), current_user: me) ==
               notifications(%{exclude_activity_types: [:boost]})

      # a string name arrives this way from the API
      assert Notifications.exclude_hidden_types(%{feed_name: "notifications"},
               current_user: me
             ) == %{feed_name: "notifications", exclude_activity_types: [:boost]}
    end

    test "leaves any other feed alone", %{me: me} do
      for feed_name <- [:my, :local, :custom, nil] do
        filters = %{feed_name: feed_name}
        assert Notifications.exclude_hidden_types(filters, current_user: me) == filters
      end
    end

    test "leaves a reader with no user alone" do
      assert Notifications.exclude_hidden_types(notifications(), []) == notifications()
    end

    test "a caller asking for everything gets everything", %{me: me} do
      assert Notifications.exclude_hidden_types(notifications(),
               current_user: me,
               include_hidden: true
             ) == notifications()
    end

    test "types the caller named explicitly outrank the preference", %{me: me} do
      filters = notifications(%{activity_types: [:boost]})
      assert Notifications.exclude_hidden_types(filters, current_user: me) == filters
    end

    test "unions with the caller's own exclusions rather than replacing them", %{me: me} do
      assert Notifications.exclude_hidden_types(
               notifications(%{exclude_activity_types: [:like]}),
               current_user: me
             ) == notifications(%{exclude_activity_types: [:like, :boost]})
    end
  end
end
