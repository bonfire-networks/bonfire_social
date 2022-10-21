defmodule Bonfire.Social.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  alias Bonfire.Data.Social.Post
  alias Bonfire.Ecto.Acts, as: Ecto

  alias Bonfire.Social.Acts.Activity
  alias Bonfire.Social.Acts.ActivityPub
  alias Bonfire.Social.Acts.Boundaries
  alias Bonfire.Social.Acts.Caretaker
  alias Bonfire.Social.Acts.Creator
  alias Bonfire.Social.Acts.Edges
  alias Bonfire.Social.Acts.Files
  alias Bonfire.Social.Acts.LivePush
  alias Bonfire.Social.Acts.MeiliSearch
  alias Bonfire.Social.Acts.Posts
  alias Bonfire.Social.Acts.Objects
  alias Bonfire.Social.Acts.PostContents
  alias Bonfire.Social.Acts.Tags
  alias Bonfire.Social.Acts.Threaded
  alias Bonfire.Social.Acts.URLPreviews

  @doc """
  NOTE: you can override this default config in your app's runtime.exs, by placing similarly-named config keys below the `Bonfire.Common.Config.LoadExtensionsConfig.load_configs` line
  """
  def config do
    import Config

    config :bonfire_social,
      disabled: false

    delete_object = [
      # Create a changeset for deletion
      {Objects.Delete, on: :object},

      # mark for deletion
      {Bonfire.Ecto.Acts.Delete,
       on: :object,
       delete_extra_associations: [
         :post_content,
         :tagged,
         :media
       ]},

      # Now we have a short critical section
      Ecto.Begin,
      # Run our deletes
      Ecto.Work,
      Ecto.Commit,
      # Enqueue for un-indexing by meilisearch
      {MeiliSearch.Queue, on: :object},

      # Oban would rather we put these here than in the transaction
      # above because it knows better than us, obviously.
      # Prepare for federation and add to deletion queue (oban).
      {ActivityPub, on: :object}
    ]

    config :bonfire_social, Bonfire.Social.Follows, []

    config :bonfire_social, Bonfire.Social.Posts,
      epics: [
        publish: [
          # Prep: a little bit of querying and a lot of preparing changesets
          # Create a changeset for insertion
          Posts.Publish,
          # with a sanitised body and tags extracted,
          PostContents,
          # a caretaker,
          {Caretaker, on: :post},
          # and a creator,
          {Creator, on: :post},
          # and possibly fetch contents of URLs,
          {URLPreviews, on: :post},
          # possibly with uploaded files,
          {Files, on: :post},
          # possibly occurring in a thread,
          {Threaded, on: :post},
          # with extracted tags fully hooked up,
          {Tags, on: :post},
          # and the appropriate boundaries established,
          {Boundaries, on: :post},
          # summarised by an activity,
          {Activity, on: :post},
          # {Feeds,       on: :post}, # appearing in feeds.

          # Now we have a short critical section
          Ecto.Begin,
          # Run our inserts
          Ecto.Work,
          Ecto.Commit,

          # These things are free to happen casually in the background.
          # Publish live feed updates via (in-memory) pubsub.
          {LivePush, on: :post},
          # Enqueue for indexing by meilisearch
          {MeiliSearch.Queue, on: :post},

          # Oban would rather we put these here than in the transaction
          # above because it knows better than us, obviously.
          # Prepare for federation and do the queue insert (oban).
          {ActivityPub, on: :post},
          # Once the activity/object exists, we can apply side effects
          {Bonfire.Social.Acts.CategoriesAutoBoost, on: :post}
        ],
        delete: delete_object
      ]

    config :bonfire_social, Bonfire.Social.Objects,
      epics: [
        delete: delete_object
      ]
  end
end
