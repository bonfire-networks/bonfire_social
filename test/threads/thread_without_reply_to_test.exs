defmodule Bonfire.Social.ThreadWithoutReplyToTest do
  @moduledoc """
  What a post that names a thread but no `reply_to_id` becomes. `Threads.find_reply_to/2` never makes it a reply (its `thread_id` fallback is commented out), so `Threaded` places it in the thread as a non-reply, via the old thread-forking `find_thread/2`, and none of the reply boundary logic applies to it.
  """
  use Bonfire.Social.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Posts
  alias Bonfire.Me.Fake

  defp publish!(user, post_attrs, opts) do
    {:ok, post} =
      Posts.publish(
        [
          current_user: user,
          post_attrs: Map.merge(%{post_content: %{html_body: "a post"}}, post_attrs)
        ] ++
          opts
      )

    Bonfire.Common.Repo.maybe_preload(post, :replied)
  end

  defp acl_ids(object),
    do: object |> Bonfire.Boundaries.Controlleds.list_on_object() |> Enum.map(& &1.acl_id)

  setup do
    alice = Fake.fake_user!()
    thread = publish!(alice, %{}, boundary: "public")
    %{alice: alice, thread: thread}
  end

  test "with only a thread_id, the post lands in that thread, but isn't a reply", %{
    thread: thread
  } do
    post = publish!(Fake.fake_user!(), %{thread_id: thread.id}, boundary: "public")
    assert post.replied.thread_id == thread.id
    assert is_nil(post.replied.reply_to_id)
  end

  test "with only a thread_id, it's refused when its author may not reply in the thread", %{
    alice: alice
  } do
    hidden_thread = publish!(alice, %{}, boundary: "mentions")
    refute Bonfire.Boundaries.can?(Fake.fake_user!(), :reply, hidden_thread)

    # the refusal raises inside the publish epic's linked task, which would take this process down unless trapped
    Process.flag(:trap_exit, true)

    assert catch_exit(
             publish!(Fake.fake_user!(), %{thread_id: hidden_thread.id}, boundary: "public")
           )
  end

  # it's a reply to the thread's opening post, just not marked as one, so its audience follows the same rule as a reply's
  describe "its audience" do
    setup %{alice: alice} do
      %{local_thread: publish!(alice, %{}, boundary: "local")}
    end

    test "with none chosen, is the opening post's", %{local_thread: thread} do
      post = publish!(Fake.fake_user!(), %{thread_id: thread.id}, [])
      assert Bonfire.Boundaries.can?(Fake.fake_user!(), :read, post), "a local user reads it"
      refute Bonfire.Boundaries.can?(:guest, :read, post), "a guest doesn't"
    end

    test "with \"Same as original post\" chosen, is the opening post's", %{local_thread: thread} do
      # as the composer sends it
      post =
        publish!(Fake.fake_user!(), %{thread_id: thread.id}, to_boundaries: ["clone_context"])

      assert Bonfire.Boundaries.can?(Fake.fake_user!(), :read, post), "a local user reads it"
      refute Bonfire.Boundaries.can?(:guest, :read, post), "a guest doesn't"
    end

    test "with a broader one chosen, is the chosen one, still excluding people the opening post's author blocked",
         %{alice: alice, local_thread: thread} do
      excluded = Fake.fake_user!()
      {:ok, _} = Bonfire.Boundaries.Blocks.block(excluded, :ghost, current_user: alice)
      post = publish!(Fake.fake_user!(), %{thread_id: thread.id}, boundary: "public")
      assert Bonfire.Boundaries.can?(:guest, :read, post), "a guest reads it"
      refute Bonfire.Boundaries.can?(excluded, :read, post), "the blocked person doesn't"
    end

    test "it stays unmarked as a reply", %{local_thread: thread} do
      post = publish!(Fake.fake_user!(), %{thread_id: thread.id}, [])
      assert post.replied.thread_id == thread.id
      assert is_nil(post.replied.reply_to_id)
    end
  end
end
