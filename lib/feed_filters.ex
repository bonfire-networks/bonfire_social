defmodule Bonfire.Social.FeedFilters do
  use TypedEctoSchema
  use Accessible
  import Ecto.Changeset
  import Untangle

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

    field :subjects, StringList
    field :exclude_subjects, StringList

    field :subject_circles, StringList
    field :exclude_subject_circles, StringList

    field :subject_types, AtomOrStringList
    field :exclude_subject_types, AtomOrStringList

    field :objects, StringList
    field :exclude_objects, StringList

    field :object_circles, StringList

    field :object_types, AtomOrStringList
    field :exclude_object_types, AtomOrStringList

    field :creators, StringList
    field :exclude_creators, StringList
    # field :creator_circles, StringList

    field :media_types, AtomOrStringList
    field :exclude_media_types, AtomOrStringList

    field :tags, StringList

    #  can be :local, :remote, or ID(s) or domain name(s) of remote instance(s)
    field :origin, AtomOrStringList

    field :time_limit, :integer, default: nil
    field :sort_order, Ecto.Enum, values: [:asc, :desc], default: :desc

    field :sort_by, Ecto.Enum,
      values: [nil, false, :date_created, :num_replies, :num_boosts, :num_likes],
      default: nil

    # NOTE: the following are meant for internal use
    # field :include_flags, Bonfire.Social.FeedFilters.Atom, default: false
    # Ecto.Enum, values: [nil, false, true, :mod, :admins]

    field :show_objects_only_once, :boolean, default: true
  end

  # TODO: how can we generate this from the list above to make sure they stay in sync?
  def supported_filters,
    do: [
      :feed_name,
      :feed_ids,
      :activity_types,
      :exclude_activity_types,
      :subjects,
      :exclude_subjects,
      :subject_circles,
      :exclude_subject_circles,
      :subject_types,
      :exclude_subject_types,
      :objects,
      :exclude_objects,
      :object_circles,
      :object_types,
      :exclude_object_types,
      :creators,
      :exclude_creators,
      # :creator_circles,
      :media_types,
      :exclude_media_types,
      :tags,
      :origin,
      :time_limit,
      :sort_by,
      :sort_order,
      #  FIXME should only be set in config
      # :include_flags,
      :show_objects_only_once
    ]

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
