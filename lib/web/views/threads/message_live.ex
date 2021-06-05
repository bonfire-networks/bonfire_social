defmodule Bonfire.Social.Web.MessageLive do
  use Bonfire.Web, :live_view
  alias Bonfire.Web.LivePlugs

  def mount(params, session, socket) do
    LivePlugs.live_plug(params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf, LivePlugs.Locale,
      &mounted/3
    ])
  end

  defp mounted(params, _session, socket) do

    current_user = e(socket, :assigns, :current_user, nil)

    # FIXME
    with {:ok, post} <- Bonfire.Social.Messages.read(Map.get(params, "id"), socket) do
      #IO.inspect(post, label: "the post:")

      {activity, object} = Map.pop(post, :activity)
      {preloaded_object, activity} = Map.pop(activity, :object)

      {:ok,
      socket
      |> assign(
        page_title: "Private Message",
        page: "Private Message",
        has_private_tab: false,
        search_placeholder: "Search this discussion",
        reply_id: Map.get(params, "reply_id"),
        activity: activity,
        object: Map.merge(object, preloaded_object),
        thread_id: e(object, :id, nil)
      ) #|> IO.inspect
      |> assign_global(
        smart_input_private: true,
        create_activity_type: "message",
        smart_input_placeholder: "Reply privately"
      )
    }

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
    # with {:ok, _boost} <- Bonfire.Social.Boosts.boost(e(socket.assigns, :current_user, nil), id) do
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
