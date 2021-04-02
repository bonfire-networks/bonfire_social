defmodule Bonfire.Social.Web.DiscussionLive do
  use Bonfire.Web, :live_view
  alias Bonfire.Fake
  alias Bonfire.Web.LivePlugs
  alias Bonfire.Me.Users
  alias Bonfire.Me.Web.{CreateUserLive, LoggedDashboardLive}
  import Bonfire.Me.Integration


  def mount(params, session, socket) do
    LivePlugs.live_plug(params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf,
      &mounted/3
    ])
  end

  defp mounted(params, session, socket) do

    current_user = e(socket, :assigns, :current_user, nil)

    # FIXME
    with {:ok, post} <- Bonfire.Social.Posts.read(Map.get(params, "id"), current_user) do
      #IO.inspect(post, label: "the post:")

      {activity, object} = Map.pop(post, :activity)

      following = if current_user && module_enabled?(Bonfire.Social.Follows) do
        a = if Bonfire.Social.Follows.following?(current_user, object), do: object.id
        thread_id = e(activity, :replied, :thread_id, nil)
        b = if thread_id && Bonfire.Social.Follows.following?(current_user, thread_id), do: thread_id
        [a, b]
      end

      {:ok,
      socket
      |> assign(
        page_title: "Discussion",
        page: "Discussion",
        reply_id: Map.get(params, "reply_id"),
        activity: activity,
        object: object,
        thread_id: e(object, :id, nil),
        following: following || []
      )}

    else _e ->
      {:error, "Not found"}
    end


  end

  # def handle_params(%{"tab" => tab} = _params, _url, socket) do
  #   {:noreply,
  #    assign(socket,
  #      selected_tab: tab
  #    )}
  # end

  # def handle_params(%{} = _params, _url, socket) do
  #   {:noreply,
  #    assign(socket,
  #      current_user: Fake.user_live()
  #    )}
  # end
  def handle_event("create_reply", %{"id"=> id}, socket) do # boost in LV
    IO.inspect(id: id)
    IO.inspect("create reply")
    # with {:ok, _boost} <- Bonfire.Social.Boosts.boost(socket.assigns.current_user, id) do
    #   {:noreply, Phoenix.LiveView.assign(socket,
    #   boosted: Map.get(socket.assigns, :boosted, []) ++ [{id, true}]
    # )}
    # end
    {:noreply, assign(socket, comment_reply_to_id: id)}
  end

  defdelegate handle_params(params, attrs, socket), to: Bonfire.Web.LiveHandler
  def handle_event(action, attrs, socket), do: Bonfire.Web.LiveHandler.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.Web.LiveHandler.handle_info(info, socket, __MODULE__)

end
