defmodule Bonfire.Social.RuntimeConfig do

  def config_module, do: true

  alias Bonfire.Data.Social.Post
  alias Bonfire.Ecto.Acts, as: Ecto
  alias Bonfire.Social.Acts.{
    Activity,
    ActivityPub,
    Boundaries,
    Caretaker,
    Creator,
    Edges,
    Feeds,
    Files,
    LivePush,
    MeiliSearch,
    Posts,
    Objects,
    PostContents,
    Tags,
    Threaded,
    URLPreviews
  }

  @doc """
  NOTE: you can override this default config in your app's runtime.exs, by placing similarly-named config keys below the `Bonfire.Common.Config.LoadExtensionsConfig.load_configs` line
  """
  def config do
    import Config

    config :bonfire_social,
      disabled: false

    delete_object = [
        # Create a changeset for deletion
        {Objects.Delete,  on: :object},

        # mark for deletion
        {Bonfire.Ecto.Acts.Delete, on: :object,
          delete_extra_associations: [
            :post_content,
            :tagged,
            :media
          ]
        },

        # Now we have a short critical section
        Ecto.Begin,
        Ecto.Work,         # Run our deletes
        Ecto.Commit,

        {MeiliSearch.Queue, on: :object},       # Enqueue for un-indexing by meilisearch

        # Oban would rather we put these here than in the transaction
        # above because it knows better than us, obviously.
        {ActivityPub, on: :object}, # Prepare for federation and add to deletion queue (oban).
      ]

    config :bonfire_social, Bonfire.Social.Follows, []

    config :bonfire_social, Bonfire.Social.Posts,
      epics: [
        publish: [
          # Prep: a little bit of querying and a lot of preparing changesets
          Posts.Publish,           # Create a changeset for insertion
          PostContents,            # with a sanitised body and tags extracted,
          {Caretaker,   on: :post}, # a caretaker,
          {Creator,     on: :post}, # and a creator,
          {URLPreviews, on: :post}, # and possibly fetch contents of URLs,
          {Files,       on: :post}, # possibly with uploaded files,
          {Threaded,    on: :post}, # possibly occurring in a thread,
          {Tags,        on: :post}, # with extracted tags fully hooked up,
          {Boundaries,  on: :post}, # and the appropriate boundaries established,
          {Activity,    on: :post}, # summarised by an activity,
          {Feeds,       on: :post}, # appearing in feeds.

          # Now we have a short critical section
          Ecto.Begin,
          Ecto.Work,         # Run our inserts
          Ecto.Commit,

          # These things are free to happen casually in the background.
          {LivePush, on: :post}, # Publish live feed updates via (in-memory) pubsub.

          {MeiliSearch.Queue, on: :post},       # Enqueue for indexing by meilisearch

          # Oban would rather we put these here than in the transaction
          # above because it knows better than us, obviously.
          {ActivityPub, on: :post}, # Prepare for federation and do the queue insert (oban).

          {Bonfire.Social.Acts.CategoriesAutoBoost, on: :post}, # Once the activity/object exists, we can apply side effects
        ],

        delete: delete_object,
      ]

    config :bonfire_social, Bonfire.Social.Objects,
      epics: [
        delete: delete_object,
      ]

  end
end
