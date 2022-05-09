defmodule Bonfire.Social.Web.HomeLive do
  use Bonfire.UI.Common.Web, :surface_view
  alias Bonfire.Me.Web.LivePlugs
  alias Bonfire.Social.Feeds.LiveHandler

  def mount(params, session, socket) do
    live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.UserRequired,
      # LivePlugs.LoadCurrentAccountUsers,
      Bonfire.UI.Common.LivePlugs.StaticChanged,
      Bonfire.UI.Common.LivePlugs.Csrf,
      Bonfire.UI.Common.LivePlugs.Locale,
      &mounted/3,
    ]
  end

  defp mounted(params, _session, socket) do
    {:ok, socket
    |> assign(
      [
        selected_tab: "home",
        page: "home",
        page_title: l("Home"),
      ])
    }
  end

  def do_handle_params(%{"tab" => "federation" = tab} = params, _url, socket) do
    {:noreply, assign(socket, LiveHandler.fediverse_feed_assigns(socket))}
  end

  def do_handle_params(%{"tab" => "local" = tab} = params, _url, socket) do

    {:noreply, assign(socket, LiveHandler.instance_feed_assigns(socket)) }
  end

  def do_handle_params(_params, _url, socket) do
    # debug("param")

    {:noreply, assign(socket, LiveHandler.default_feed_assigns(socket))}
  end


  # defdelegate handle_params(params, attrs, socket), to: Bonfire.UI.Common.LiveHandlers
  def handle_params(params, uri, socket) do
    # poor man's hook I guess
    with {_, socket} <- Bonfire.UI.Common.LiveHandlers.handle_params(params, uri, socket) do
      undead_params(socket, fn ->
        do_handle_params(params, uri, socket)
      end)
    end
  end
  def handle_event(action, attrs, socket), do: Bonfire.UI.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.UI.Common.LiveHandlers.handle_info(info, socket, __MODULE__)


end
