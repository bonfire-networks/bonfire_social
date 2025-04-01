defmodule Bonfire.Social.NotificationEmailsTest do
  # Use the module
  use Bonfire.Social.DataCase, async: true

  import Swoosh.TestAssertions
  alias Bonfire.Posts

  setup do
    Process.put([:bonfire_mailer, Bonfire.Mailer, :mailer_behaviour], Bonfire.Mailer.Swoosh)

    Process.put([:bonfire, :email_notifications, :reply_or_mentions], true)

    on_exit(fn -> Process.delete([:bonfire_mailer, Bonfire.Mailer, :mailer_behaviour]) end)
  end

  test "standard integration works" do
    account = fake_account!()
    alice = fake_user!(account)

    account2 = fake_account!()
    bob = fake_user!(account2)

    account3 = fake_account!()
    carl = fake_user!(account3)

    # Follows.follow(alice, bob)

    attrs = %{
      post_content: %{summary: "summary", name: "test post name", html_body: "<p>first post</p>"}
    }

    assert {:ok, post} = Posts.publish(current_user: alice, post_attrs: attrs, boundary: "public")

    # Reply to the original post
    attrs_reply = %{
      post_content: %{
        summary: "summary",
        name: "name 2",
        html_body: "reply to first post @#{carl.character.username}"
      },
      reply_to_id: post.id
    }

    assert {:ok, post_reply} =
             Posts.publish(current_user: bob, post_attrs: attrs_reply, boundary: "public")

    # assert an email with specific field(s) was sent
    # assert_email_sent(subject: "test - bonfire Hello, Avengers!")

    # assert an email that satisfies a condition
    assert_email_sent(fn email ->
      assert length(email.to) == 1
      assert email.text_body =~ bob.profile.name
    end)
  end
end
