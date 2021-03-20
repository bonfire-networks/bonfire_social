defmodule Bonfire.Social.Web.Feeds.InstanceLive do
  use Bonfire.Web, :live_view
  alias Bonfire.Fake
  alias Bonfire.Web.LivePlugs
  alias Bonfire.Me.Users
  alias Bonfire.Me.Web.{CreateUserLive}

  def mount(params, session, socket) do
    LivePlugs.live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf,
      &mounted/3,
    ]
  end

  defp mounted(params, session, socket) do

    feed_id = Bonfire.Social.Feeds.instance_feed_id()

    feed = Bonfire.Social.FeedActivities.feed(feed_id, e(socket.assigns, :current_user, nil))

    title = "Feed of all activities by users on this instance"
    {:ok, socket
    |> assign(
      page: "instance",
      page_title: "Instance Feed",
      smart_input: true,
      feed_title: title,
      feed_id: feed_id,
      feed: e(feed, :entries, []),
      page_info: e(feed, :metadata, [])
      )}
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
  defdelegate handle_event(action, attrs, socket), to: Bonfire.Web.LiveHandler
  defdelegate handle_info(info, socket), to: Bonfire.Web.LiveHandler

end
