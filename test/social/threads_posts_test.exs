defmodule Bonfire.Social.ThreadsPostsTest do
  use Bonfire.DataCase

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Threads
  alias Bonfire.Me.Fake

  test "reply works" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs)

    attrs_reply = %{post_content: %{summary: "summary", name: "name 2", html_body: "<p>epic html message</p>"}, reply_to_id: post.id}
    assert {:ok, post_reply} = Posts.publish(user, attrs_reply)

    # IO.inspect(post_reply)
    assert post_reply.replied.reply_to_id == post.id
    assert post_reply.replied.thread_id == post.id
  end

  test "fetching a reply works" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs)

    attrs_reply = %{post_content: %{summary: "summary", name: "name 2", html_body: "<p>epic html message</p>"}, reply_to_id: post.id}
    assert {:ok, post_reply} = Posts.publish(user, attrs_reply)

    assert {:ok, read} = Posts.read(post_reply.id, user)

    # IO.inspect(read)
    assert read.activity.replied.reply_to_id == post.id
    assert read.activity.replied.thread_id == post.id
  end

  test "can fetch a thread" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs)

    attrs_reply = %{post_content: %{summary: "summary", name: "name 2", html_body: "<p>epic html message</p>"}, reply_to_id: post.id}
    assert {:ok, post_reply} = Posts.publish(user, attrs_reply)

    assert %{entries: replies} = Threads.list_replies(post.id, user)

    # IO.inspect(replies)
    reply = List.first(replies)
    assert reply.activity.replied.reply_to_id == post.id
    assert reply.activity.replied.thread_id == post.id
    assert reply.activity.replied.path == [post.id]
  end

  test "can do nested replies" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs)

    attrs_reply = %{post_content: %{summary: "summary", name: "name 2", html_body: "<p>epic html message</p>"}, reply_to_id: post.id}
    assert {:ok, post_reply} = Posts.publish(user, attrs_reply)

    attrs_reply3 = %{post_content: %{summary: "summary", name: "name 3", html_body: "<p>epic html message</p>"}, reply_to_id: post_reply.id}
    assert {:ok, post_reply3} = Posts.publish(user, attrs_reply3)

    assert %{entries: replies} = Threads.list_replies(post.id, user)

    # IO.inspect(replies)
    assert length(replies) == 2
    reply = List.last(replies)
    reply3 = List.first(replies)

    assert reply.activity.replied.reply_to_id == post.id
    assert reply.activity.replied.thread_id == post.id
    assert reply.activity.replied.path == [post.id]

    assert reply3.activity.replied.reply_to_id == post_reply.id
    assert reply3.activity.replied.thread_id == post.id
    assert reply3.activity.replied.path == [post.id, post_reply.id]
  end

  test "can do nested replies, with a forked thread" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs)

    attrs_reply = %{post_content: %{summary: "summary", name: "name 2", html_body: "<p>epic html message</p>"}, reply_to_id: post.id}
    assert {:ok, post_reply} = Posts.publish(user, attrs_reply)

    attrs_reply3 = %{post_content: %{summary: "summary", name: "name 3", html_body: "<p>epic html message</p>"}, reply_to_id: post_reply.id, thread_id: post_reply.id}
    assert {:ok, post_reply3} = Posts.publish(user, attrs_reply3)

    assert %{entries: replies} = Threads.list_replies(post.id, user)

    # IO.inspect(replies)
    assert length(replies) == 2
    reply = List.last(replies)
    reply3 = List.first(replies)

    assert reply.activity.replied.reply_to_id == post.id
    assert reply.activity.replied.thread_id == post.id
    assert reply.activity.replied.path == [post.id]

    assert reply3.activity.replied.reply_to_id == post_reply.id
    assert reply3.activity.replied.thread_id == post_reply.id
    assert reply3.activity.replied.path == [post.id, post_reply.id]
  end

  test "can arrange nested replies into a tree" do
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    user = Fake.fake_user!()
    assert {:ok, post} = Posts.publish(user, attrs)

    attrs_reply = %{post_content: %{summary: "summary", name: "name 2", html_body: "<p>epic html message</p>"}, reply_to_id: post.id}
    assert {:ok, post_reply} = Posts.publish(user, attrs_reply)

    attrs_reply3 = %{post_content: %{summary: "summary", name: "name 3", html_body: "<p>epic html message</p>"}, reply_to_id: post_reply.id}
    assert {:ok, post_reply3} = Posts.publish(user, attrs_reply3)

    assert %{entries: replies} = Threads.list_replies(post.id, user)

    threaded_replies = Bonfire.Social.Threads.arrange_replies_tree(replies)

    # IO.inspect(threaded_replies)
    assert [{
      %{} = reply,
      [{
        %{} = reply3,
        []
      }]
    }] = threaded_replies

    assert reply.activity.replied.reply_to_id == post.id
    assert reply.activity.replied.thread_id == post.id
    assert reply.activity.replied.path == [post.id]

    assert reply3.activity.replied.reply_to_id == post_reply.id
    assert reply3.activity.replied.thread_id == post.id
    assert reply3.activity.replied.path == [post.id, post_reply.id]
  end


end
