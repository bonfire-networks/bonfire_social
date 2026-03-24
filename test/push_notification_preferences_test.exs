defmodule Bonfire.Social.PushNotificationPreferencesTest do
  use Bonfire.Social.DataCase, async: false

  use Bonfire.Common.Utils

  import Bonfire.Social.Fake

  alias Bonfire.Social.Feeds
  alias Bonfire.Common.Settings

  setup do
    prev = Application.get_env(:ex_nudge, :vapid_details)

    Application.put_env(:ex_nudge, :vapid_details,
      vapid_public_key: "test_public_key",
      vapid_private_key: "test_private_key",
      vapid_subject: "mailto:test@example.com"
    )

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ex_nudge, :vapid_details, prev),
        else: Application.delete_env(:ex_nudge, :vapid_details)
    end)

    :ok
  end

  describe "push notification preferences" do
    test "sends to user when no preferences set (defaults enabled)" do
      creator = fake_user!()
      user = fake_user!()
      feed_id = Feeds.feed_id(:notifications, user)

      object = %{
        id: Needle.ULID.generate(),
        title: "someone liked",
        message: "your post",
        url: "/test",
        notify_category: :likes,
        creator: creator
      }

      # Reaches WebPush but no device registered
      assert {:error, :no_subscriptions} = Bonfire.Notify.notify(object, [feed_id])
    end

    test "filters out user who disabled a notification category" do
      creator = fake_user!()
      user = fake_user!()
      feed_id = Feeds.feed_id(:notifications, user)

      Settings.put([:push_notifications, :likes], false, current_user: user)

      object = %{
        id: Needle.ULID.generate(),
        title: "someone liked",
        message: "your post",
        url: "/test",
        notify_category: :likes,
        creator: creator
      }

      assert {:error, :no_valid_recipients} = Bonfire.Notify.notify(object, [feed_id])
    end

    test "only filters the specific disabled category" do
      creator = fake_user!()
      user = fake_user!()
      feed_id = Feeds.feed_id(:notifications, user)

      Settings.put([:push_notifications, :likes], false, current_user: user)

      # Likes disabled — should be filtered
      likes_object = %{
        id: Needle.ULID.generate(),
        title: "someone liked",
        message: "your post",
        url: "/test",
        notify_category: :likes,
        creator: creator
      }

      assert {:error, :no_valid_recipients} = Bonfire.Notify.notify(likes_object, [feed_id])

      # Boosts still enabled — should reach WebPush
      boosts_object = %{
        id: Needle.ULID.generate(),
        title: "someone boosted",
        message: "your post",
        url: "/test",
        notify_category: :boosts,
        creator: creator
      }

      assert {:error, :no_subscriptions} = Bonfire.Notify.notify(boosts_object, [feed_id])
    end

    test "filters correctly with multiple users" do
      creator = fake_user!()
      user_on = fake_user!()
      user_off = fake_user!()

      Settings.put([:push_notifications, :likes], false, current_user: user_off)

      feed_id_on = Feeds.feed_id(:notifications, user_on)
      feed_id_off = Feeds.feed_id(:notifications, user_off)

      object = %{
        id: Needle.ULID.generate(),
        title: "someone liked",
        message: "your post",
        url: "/test",
        notify_category: :likes,
        creator: creator
      }

      # user_off is filtered, user_on passes through to WebPush (no device = no_subscriptions)
      assert {:error, :no_subscriptions} =
               Bonfire.Notify.notify(object, [feed_id_on, feed_id_off])
    end
  end
end
