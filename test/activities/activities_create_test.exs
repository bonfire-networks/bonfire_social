defmodule Bonfire.Social.ActivitiesCreateTest do
  @moduledoc """
  An activity created with a subject that is a plain map (not a schema struct), as ValueFlows passes its agents, must still be preloadable and pushed live.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  import Bonfire.Posts.Fake, only: [fake_post!: 3]

  alias Bonfire.Social.Activities
  alias Bonfire.Me.Fake

  test "an activity whose subject was given as a plain map can be preloaded and pushed live" do
    me = Fake.fake_user!()
    post = fake_post!(me, "public", %{post_content: %{html_body: "a post"}})

    # the shape ValueFlows uses for an agent: a map with the user's id, not a struct
    agent = %{
      id: me.id,
      name: "someone",
      agent_type: :person,
      __typename: Bonfire.Data.Identity.User
    }

    # as `Objects.publish` does: the activity takes the object's own id
    assert {:ok, %Bonfire.Data.Social.Activity{} = activity} =
             Activities.create(agent, :create, post)

    assert %Bonfire.Data.Social.Activity{} =
             Bonfire.Social.LivePush.emit_live(activity, [me.character.outbox_id], [])
  end
end
