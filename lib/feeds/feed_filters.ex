defmodule Bonfire.Social.FeedFilters do
  use TypedEctoSchema
  use Accessible
  import Ecto.Changeset
  import Untangle
  require Exto

  alias Bonfire.Common.Enums
  alias Bonfire.Common.Types
  alias Bonfire.Social.FeedFilters
  alias FeedFilters.StringList
  alias FeedFilters.AtomOrStringList

  @primary_key false
  typed_embedded_schema do
    field :feed_name, Bonfire.Social.FeedFilters.Atom, default: :custom

    # Ecto.Enum, values: [:my, :explore, :remote, :local, :curated, :likes, :bookmarks, :flags, :custom]

    field :feed_ids, StringList

    field :activity_types, AtomOrStringList
    field :exclude_activity_types, AtomOrStringList

    field :subjects, AtomOrStringList
    field :exclude_subjects, AtomOrStringList

    # TODO: move to `bonfire_boundaries`, which owns the Encircle row these join: declare the keys in its config for `Exto` to add here (see `flex_schema` at the end of this block) and implement `Bonfire.Common.FeedFilterModule` there for the query, as `bonfire_tag` does for `tags`. Takes the two commented-out circle filters below with it
    field :subject_circles, StringList
    field :exclude_subject_circles, StringList

    field :subject_types, AtomOrStringList
    field :exclude_subject_types, AtomOrStringList
    # Compound filter behind the UI's single "Group activities" switch — see
    # FeedLoader.expand_exclude_group_activities/1, which expands it at query time.
    field :exclude_group_activities, :boolean
    # NOTE: no defaults on the booleans below — a default would be baked into every validated
    # struct and clobber a user-set true when merging partial filter updates (nil = "not set")
    # TODO: move to `bonfire_classify` the same way (its config declares the key for `Exto`, it implements `Bonfire.Common.FeedFilterModule` for the query), along with the Category-shaped `exclude_subject_types` expansion `FeedLoader` does beside it
    field :exclude_category_contexts, :boolean

    # notification categories as conditions: rows matching any of these, or none of them. A category is what `Bonfire.Social.Notifications.query_filters_for/2` says it selects, so these reach it rather than restating it; this is how the centre's switches and the Mastodon API's `types[]`/`exclude_types[]` ask for one
    field :notification_categories, AtomOrStringList
    field :exclude_notification_categories, AtomOrStringList

    # asks by where they stand. A list, since statuses combine; `:pending` also keeps what is not an ask, which has no request row, so it can quiet a mixed feed as well as narrow a list of asks
    field :request_status, {:array, Ecto.Enum}, values: [:pending, :accepted, :ignored]

    field :objects, StringList
    field :exclude_objects, StringList

    field :object_types, AtomOrStringList
    field :exclude_object_types, AtomOrStringList

    # FEP-8a8e event categories (matched against the AS2 `category` in an APActivity's json)
    # TODO: clearer name? also moves with events, wherever they end up living (`lib/events/` here today): same two halves, a config declaration for `Exto` and a `Bonfire.Common.FeedFilterModule` implementation for the query
    field :object_categories, AtomOrStringList

    field :creators, StringList
    field :exclude_creators, StringList
    # field :creator_circles, StringList

    # field :object_circles, StringList

    # `media_types`/`exclude_media_types` are declared by `bonfire_files`, which owns media and the join that reaches them

    #  can be :local, :remote, or ID(s) or domain name(s) of remote instance(s)
    field :origin, AtomOrStringList

    field :time_limit, :integer, default: nil
    field :sort_order, Ecto.Enum, values: [:asc, :desc], default: :desc

    field :sort_by, Ecto.Enum,
      values: [
        nil,
        false,
        :date_created,
        :reply_count,
        :boost_count,
        :like_count,
        :latest_reply,
        :popularity_score
      ],
      default: nil

    # NOTE: the following are meant for internal use
    # field :include_flags, Bonfire.Social.FeedFilters.Atom, default: false
    # Ecto.Enum, values: [nil, false, true, :mod, :admins]

    field :show_objects_only_once, :boolean, default: true
    field :dedup_by_like_or_boost, :boolean, default: true
    field :dedup_by_thread, :boolean, default: false
    field :dedup_replies_by_parent, :boolean, default: false

    # Pagination fields for Mastodon API compatibility
    field :id_before, :string
    field :id_after, :string

    # what an extension adds to this struct from its own config, declared the way a data schema's fields and assocs are (`config :bonfire_social, Bonfire.Social.FeedFilters, field: [my_filter: {:boolean, default: nil}]`). Read at compile time, so a change to that config needs this dep rebuilt, and a field arrives without the typespec the ones above carry. A field declared here is validated and carried; making it *filter* takes a handler as well
    Exto.flex_schema(:bonfire_social)
  end

  @doc """
  The filter keys this struct accepts, which is every field it has, including the ones an extension declared in config.

  Derived rather than listed, since it is extensible.
  """
  def supported_filters, do: __schema__(:fields)

  @doc """
  Creates a changeset for feed filters.

  ## Examples

      iex> #Ecto.Changeset<changes: %{feed_name: :explore, object_types: ["post"]}, errors: [], valid?: true> = changeset(%{feed_name: "explore", object_types: ["post"]})
  """
  def changeset(filters \\ %__MODULE__{}, attrs)

  def changeset(filters, %{feed_name: feed_name} = attrs) when is_binary(feed_name) do
    case Types.maybe_to_atom!(feed_name) do
      nil -> changeset(filters, Map.drop(attrs, [:feed_name]))
      feed_name -> changeset(filters, Map.put(attrs, :feed_name, feed_name))
    end
  end

  def changeset(filters, attrs) do
    filters
    |> cast(
      Enums.input_to_atoms(attrs, also_discard_unknown_nested_keys: false) |> debug("input"),
      supported_filters()
    )
    # |> validate_length(:feed_ids, min: 1, message: "must have at least one feed ID")
    # |> validate_length(:tags, min: 1, message: "must have at least one tag")
    |> validate_number(:time_limit, greater_than_or_equal_to: 0)

    # |> validate_required([:feed_name])
    # |> validate_exclusion(:feed_name, [nil])
    # |> validate_mutex([:exclude_replies, :only_replies],
    #   message: "cannot both exclude and only show replies"
    # )
  end

  @doc """
  Creates a changeset and validates the data, returning either validated filters or errors.

  ## Examples

      iex> {:ok, %FeedFilters{feed_name: :explore, object_types: [:post]}} = 
      ...> validate(%{feed_name: :explore, object_types: "post"})
      
      iex> {:ok, %FeedFilters{feed_name: :explore, object_types: [:post]}} = 
      ...> validate(%{feed_name: "explore", object_types: ["post"]})

      iex> {:ok, %FeedFilters{feed_name: :explore, object_types: [:post]}} = 
      ...> validate(%{"feed_name"=> "explore", "object_types"=> "post"})

      iex> {:ok, %FeedFilters{feed_name: nil, object_types: [:post]}} = 
      ...> validate(%{feed_name: nil, object_types: :post})

      iex> {:ok, %FeedFilters{object_types: [:post]}} = 
      ...> validate(%{object_types: "post"})

      iex> {:ok, %FeedFilters{feed_name: :custom}} = 
      ...> validate(%{feed_name: "my_custom_feed"}) 
  """
  # TODO: re-validate?
  def validate(%FeedFilters{} = attrs), do: {:ok, attrs}

  def validate(%Ecto.Changeset{valid?: true} = changeset),
    do: {:ok, Ecto.Changeset.apply_changes(changeset)}

  def validate(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  def validate(attrs) when is_map(attrs) do
    case changeset(attrs) do
      %{valid?: true} = changeset ->
        {:ok, Ecto.Changeset.apply_changes(changeset)}

      cs ->
        warn(attrs, "Invalid filters")
        error(cs)
    end
  end

  def validate(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      validate(Map.new(attrs))
    else
      error(attrs, "Invalid filter parameters")
    end
  end

  def validate(attrs) do
    error(attrs, "Invalid filter parameters")
  end

  @doc """
  Reduces a user-typed instance reference to a bare domain for the `:origin` filter.

      iex> normalise_instance_domain("https://Mastodon.social/about")
      "mastodon.social"
      iex> normalise_instance_domain("@gancio.org")
      "gancio.org"
      iex> normalise_instance_domain("not-a-domain")
      nil
  """
  def normalise_instance_domain(domain) when is_binary(domain) do
    domain =
      domain
      |> String.trim()
      |> String.replace(~r{^[a-z]+://}i, "")
      |> String.trim_leading("@")
      |> String.split("/")
      |> hd()
      |> String.downcase()

    if String.contains?(domain, ".") and not String.contains?(domain, [" ", "#"]), do: domain
  end

  def normalise_instance_domain(_), do: nil

  # Custom validators

  defp validate_mutex(changeset, fields, opts) do
    if Enum.any?(fields, &get_field(changeset, &1)) and
         Enum.any?(fields, &get_field(changeset, &1)) do
      add_error(changeset, hd(fields), opts[:message] || "mutually exclusive fields")
    else
      changeset
    end
  end
end
