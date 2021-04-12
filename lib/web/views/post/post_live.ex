defmodule Bonfire.Social.Web.PostLive do
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
      LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf,
      &mounted/3
    ])
  end

  defp mounted(params, session, socket) do

    current_user = e(socket, :assigns, :current_user, nil)

    with {:ok, post} <- Bonfire.Social.Posts.read(Map.get(params, "id"), current_user) do
      #IO.inspect(post, label: "the post:")

      {activity, object} = Map.pop(post, :activity)

      following = if current_user && module_enabled?(Bonfire.Social.Follows) && Bonfire.Social.Follows.following?(current_user, object), do: [object.id]


      {:ok,
      socket
      |> assign(
        page_title: "Post",
        page: "Discussion",
        has_private_tab: false,
        reply_id: Map.get(params, "reply_id"),
        activity: activity,
        object: object,
        thread_id: e(object, :id, nil),
        replies: [],
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

  defdelegate handle_params(params, attrs, socket), to: Bonfire.Web.LiveHandler
  def handle_event(action, attrs, socket), do: Bonfire.Web.LiveHandler.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.Web.LiveHandler.handle_info(info, socket, __MODULE__)

end
