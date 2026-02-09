if Application.compile_env(:bonfire_social, :modularity) != :disabled do
  defmodule Bonfire.Social.Events.MastoEventsController do
    @moduledoc "Mastodon-compatible events REST endpoints."

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Social.Events.API.GraphQLMasto.EventsAdapter

    def events_timeline(conn, params), do: EventsAdapter.list_events(params, conn)

    def user_events(conn, %{"id" => user_id} = params),
      do: EventsAdapter.list_user_events(user_id, params, conn)

    def show(conn, %{"id" => id}), do: EventsAdapter.show_event(id, conn)
  end
end
