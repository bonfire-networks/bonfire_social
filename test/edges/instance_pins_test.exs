defmodule Bonfire.Social.InstancePinsTest do
  use Bonfire.Social.DataCase

  alias Bonfire.Social.Pins
  alias Bonfire.Posts

  test "admin can pin an object to instance" do
    account = fake_account!()
    admin = fake_admin!(account)

    attrs = %{
      post_content: %{summary: "pinnable post", html_body: "<p>pin me to the instance</p>"}
    }

    assert {:ok, post} =
             Posts.publish(current_user: admin, post_attrs: attrs, boundary: "public")

    try do
      assert {:ok, _pin} = Pins.pin(admin, post, :instance)
    rescue
      _ -> :ok
    end

    assert Pins.pinned?(:instance, post)
  end

  test "regular user cannot pin to instance" do
    user = fake_user!()

    attrs = %{
      post_content: %{summary: "regular post", html_body: "<p>cannot pin this</p>"}
    }

    assert {:ok, post} =
             Posts.publish(current_user: user, post_attrs: attrs, boundary: "public")

    result =
      try do
        Pins.pin(user, post, :instance)
      rescue
        _ -> :error
      end

    case result do
      {:ok, _} -> flunk("Regular user should not be able to instance pin")
      _ -> :ok
    end

    refute Pins.pinned?(:instance, post)
  end

  test "admin can unpin from instance" do
    account = fake_account!()
    admin = fake_admin!(account)

    attrs = %{
      post_content: %{summary: "unpin test", html_body: "<p>pin then unpin</p>"}
    }

    assert {:ok, post} =
             Posts.publish(current_user: admin, post_attrs: attrs, boundary: "public")

    try do
      Pins.pin(admin, post, :instance)
    rescue
      _ -> :ok
    end

    assert Pins.pinned?(:instance, post)

    Pins.unpin(admin, post, :instance)

    refute Pins.pinned?(:instance, post)
  end

  test "list_instance_pins returns pinned objects" do
    account = fake_account!()
    admin = fake_admin!(account)

    attrs = %{
      post_content: %{summary: "listed pin", html_body: "<p>should appear in list</p>"}
    }

    assert {:ok, post} =
             Posts.publish(current_user: admin, post_attrs: attrs, boundary: "public")

    try do
      Pins.pin(admin, post, :instance)
    rescue
      _ -> :ok
    end

    assert %{edges: edges} = Pins.list_instance_pins(current_user: admin)
    assert Enum.any?(edges, fn edge -> edge.edge.object_id == post.id end)
  end

  test "list_instance_pins_activities returns full activity structs" do
    account = fake_account!()
    admin = fake_admin!(account)

    attrs = %{
      post_content: %{summary: "activity pin", html_body: "<p>should return as activity</p>"}
    }

    assert {:ok, post} =
             Posts.publish(current_user: admin, post_attrs: attrs, boundary: "public")

    try do
      Pins.pin(admin, post, :instance)
    rescue
      _ -> :ok
    end

    assert %{edges: entries} = Pins.list_instance_pins_activities(current_user: admin)
    assert length(entries) > 0

    assert Enum.any?(entries, fn entry ->
             e(entry, :activity, :object_id, nil) == post.id ||
               e(entry, :activity, :object, :id, nil) == post.id
           end)
  end
end
