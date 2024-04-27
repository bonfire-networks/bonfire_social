if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQLMasto.Adapter do
    use Arrows
    import Untangle

    use AbsintheClient,
      schema: Bonfire.API.GraphQL.Schema,
      action: [mode: :internal]

    alias Bonfire.API.GraphQL.RestAdapter
    alias Bonfire.Common.Utils
    alias Bonfire.Common.Enums
    alias Bonfire.Me.API.GraphQLMasto.Adapter, as: MeAdapter

    @post_content "
    name
    summary
    content: html_body
    "

    @user Utils.maybe_apply(MeAdapter, :user_profile_query, [], fallback_return: "id")

    @activity "
    id
    created_at: date
    uri: canonical_uri
    url
    account: subject {
      ... on User {
        #{@user}
    }}
    object_post_content {
      #{@post_content}
    }
    "

    # @graphql "query ($filter: PostFilters) {
    #   post(filter: $filter) {
    #     #{@post_content}
    # }}"
    # def post(params, conn) do
    #   post = graphql(conn, :post, debug(params))

    #   RestAdapter.return(:post, post, conn, &prepare_post/1)
    # end

    @graphql "query ($filter: FeedFilters) {
      feed(filter: $filter) {
      edges { node {
              #{@activity}
      }}
    }}"
    def feed(params, conn) do
      feed = graphql(conn, :feed, debug(params))

      RestAdapter.return(:feed, feed, conn, &prepare_feed/1)
    end

    defp prepare_feed(%{edges: edges}) do
      Enum.map(edges, &prepare_activity/1)
      |> debug()
    end

    defp prepare_activity(%{node: activity}), do: prepare_activity(activity)

    defp prepare_activity(activity) do
      {nested, flat} = Map.split(activity, [:account])

      # TODO: implement these fields
      Map.merge(
        %{
          "visibility" => "private",
          "sensitive" => false,
          "spoiler_text" => "",
          "application" => nil,
          "bookmarked" => false,
          "card" => nil,
          "emojis" => [],
          "favourited" => false,
          "favourites_count" => 0,
          "in_reply_to_account_id" => nil,
          "in_reply_to_id" => nil,
          "language" => nil,
          "media_attachments" => [],
          "mentions" => [],
          "tags" => [],
          "muted" => false,
          "pinned" => false,
          # "pleroma" => %{
          #   "content" => %{"text/plain" => "foobar"},
          #   "context" => "http://localhost:4001/objects/8b4c0c80-6a37-4d2a-b1b9-05a19e3875aa",
          #   "conversation_id" => 345_972,
          #   "direct_conversation_id" => nil,
          #   "emoji_reactions" => [],
          #   "expires_at" => nil,
          #   "in_reply_to_account_acct" => nil,
          #   "local" => true,
          #   "spoiler_text" => %{"text/plain" => ""},
          #   "thread_muted" => false
          # },
          "poll" => nil,
          "reblog" => nil,
          "reblogged" => false,
          "reblogs_count" => 0,
          "replies_count" => 0
        },
        Enums.maybe_flatten(flat)
        |> Map.merge(
          Enum.map(nested, fn
            {:account = k, v} ->
              {k, Utils.maybe_apply(MeAdapter, :prepare_user, v, fallback_return: v)}

            {k, v} ->
              {k, Enums.maybe_flatten(v)}
          end)
          |> Map.new()
        )
      )
      |> debug()
    end

    defp prepare_post(user) do
      # TODO: implement these fields
      %{
        # "locked"=> false,
      }
      |> Map.merge(
        user
        |> Enums.maybe_flatten()
        # |> Enums.map_put_default(:note, "") # because some clients don't accept nil
      )
      |> debug()
    end
  end
end
