defmodule Bonfire.Social.API.GraphQLMasto.NotificationCandidate do
  @moduledoc """
  Internal notification candidate resolved from Bonfire activities.

  Deliberately not a Mastodon entity: it captures the Bonfire semantics serializers need (who
  caused the notification, which kind, and which post to attach when a status is required).
  """

  @enforce_keys [:id, :type, :activity]
  defstruct [
    :id,
    :type,
    :activity,
    :actor,
    :actor_id,
    :object_id,
    :status_post,
    :created_at,
    status_context: [],
    mentions: []
  ]
end
