defmodule Bonfire.Social.Notifications do
  @moduledoc """
  Notification categories, and the per-user preferences that filter them.

  A category is one kind of thing you get notified about ("Likes", "Replies"), declared in config
  with the activity types it covers. One declaration feeds both notification-centre surfaces: the
  category tabs and the "Notify me about" switches.

  This lives in a context rather than in the UI because the notifications feed is not the only
  reader. The Mastodon API builds its own filter map (`Bonfire.Social.API.GraphQLMasto.Notifications`),
  the unseen badge counts rows directly, and the digest and fan-out worker ask the same questions,
  so a resolution that sat in a LiveView would make one preference behave differently per surface.
  """
  use Bonfire.Common.E
  use Bonfire.Common.Config
  use Bonfire.Common.Settings
  use Bonfire.Common.Localise

  import Ecto.Query, only: [dynamic: 1, dynamic: 2, where: 2, where: 3, select: 2, exclude: 2]

  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Common.Types
  alias Bonfire.Common.Utils

  # the `notification_categories`/`exclude_notification_categories` feed filters, which turn a category into a condition
  @behaviour Bonfire.Common.FeedFilterModule

  @doc """
  Notification categories in display order, from config.

  Each entry may declare the `activity_types` it covers (defaulting to the verb its key names), a
  plural `name_pluralized` and `icon` for surfaces that show it, `path_aliases` for its URLs, and
  where it appears: `chip` and `row` are `true`, `false`, or `:unimplemented` for a category
  nothing honours yet, which then shows only behind the `:show_unimplemented` flag.
  """
  def categories do
    Config.get([__MODULE__, :categories], [],
      name: l("Notification categories"),
      description: l("Which kinds of notification this instance distinguishes.")
    )
  end

  @doc "One category by key, or nil."
  def category(key), do: categories() |> e(key, nil)

  @doc """
  The activity types a category covers, defaulting to the verb its key names.

  Only a category's verbs: what it selects in a feed is `query_filters_for/2`, which starts from these when a category declares no filters of its own.
  """
  def activity_types_for(key) do
    # not `e/3`, which reads an empty list as nothing set, while `activity_types: []` means "every type" for the default category
    case category(key) do
      %{activity_types: types} -> types
      _ -> [key]
    end
  end

  @doc """
  What a category selects in a feed query, for the person reading: its `filters:` with its `parameterized:` resolved for them (`tags: [:me]` becomes the reader), or its activity types when it declares no filters.

  The query side of what a category is, and the only one: chips apply it directly, and the centre's switches and the Mastodon API's type filters reach it through the `notification_categories`/`exclude_notification_categories` feed filters. The in-memory side is `Bonfire.Social.Activities.experienced_as/2` with each category's `experiences:`, which is what push, email, a row's wording and the Mastodon type go by, since fan-out decides per recipient without a query each. The two cannot share code, so `Bonfire.Social.NotificationCategoriesEquivalenceTest` holds them together: change what a category selects here, or what `experienced_as/2` answers, and that test says whether the other needs the same change.
  """
  def query_filters_for(key, opts \\ []) do
    category = category(key)

    if e(category, :catch_all, nil) do
      # what no other chip shows, each excluded as exactly what it selects, so a new chip narrows this by itself
      %{exclude_notification_categories: chipped_categories_besides(key)}
    else
      # kept apart from `filters:` the way a preset keeps them, because resolving a plain value as a parameter logs it as a missing one
      Bonfire.Social.FeedLoader.parameterize_filters(
        e(category, :filters, nil) || %{activity_types: activity_types_for(key)},
        e(category, :parameterized, nil) || %{},
        current_user: Utils.current_user(opts)
      )
    end
  end

  # the chips a catch-all is the rest of: not itself or another catch-all, and not a chip that selects everything (Latest), which would leave nothing
  defp chipped_categories_besides(key) do
    categories_shown(:chip)
    |> Enum.reject(fn {other_key, category} ->
      other_key == key or e(category, :catch_all, nil) == true or
        (is_nil(e(category, :filters, nil)) and activity_types_for(other_key) == [])
    end)
    |> Enum.map(fn {other_key, _category} -> other_key end)
  end

  @impl Bonfire.Common.FeedFilterModule
  def feed_filter_module, do: __MODULE__

  @impl Bonfire.Common.FeedFilterModule
  @doc """
  Categories as conditions on a feed query: `notification_categories` keeps rows any of them selects, `exclude_notification_categories` keeps rows none of them does.

  Each category is what `query_filters_for/2` says it selects, so a switch hides exactly what its chip shows and the Mastodon API's type filters agree with both.
  """
  def maybe_filter(query, filter, opts \\ [])

  def maybe_filter(query, {:notification_categories, keys}, opts)
      when is_list(keys) and keys != [] do
    where(
      query,
      ^Enum.reduce(keys, dynamic(false), fn key, any ->
        dynamic(^any or ^category_condition(key, opts))
      end)
    )
  end

  def maybe_filter(query, {:exclude_notification_categories, keys}, opts)
      when is_list(keys) and keys != [] do
    where(
      query,
      ^Enum.reduce(keys, dynamic(true), fn key, none ->
        dynamic(^none and not (^category_condition(key, opts)))
      end)
    )
  end

  def maybe_filter(query, _filter, _opts), do: query

  # a category whose filters are verbs alone is a plain test on the row; any other runs its own filters, unchanged, inside a correlated subquery shaped like a feed's, which is what every filter module expects
  defp category_condition(key, opts) do
    case query_filters_for(Types.maybe_to_atom!(key), opts) do
      # `[]` is "every type", as for the default category
      %{activity_types: []} = filters when map_size(filters) == 1 ->
        dynamic(true)

      # the same test `Activities.maybe_filter/3` applies for `activity_types`, written as a condition to spare a subquery for every verbs-only category a switch hides; keep the two in step
      %{activity_types: types} = filters when map_size(filters) == 1 ->
        verb_ids = Verbs.ids(types)
        dynamic([activity: activity], activity.verb_id in ^verb_ids)

      filters ->
        # prepared as a feed's filters are (`exclude_object_types` becomes `exclude_table_ids` there, for one), and with the outer feed's opts, so a category selects the same as a condition as it does as a chip
        {filters, opts} =
          Bonfire.Social.FeedLoader.prepare_filters_and_opts(filters, [], opts)

        matching =
          Bonfire.Social.FeedActivities.base_query(opts)
          |> where([activity: activity], activity.id == parent_as(:activity).id)
          |> Bonfire.Social.FeedLoader.maybe_filter(filters, opts)
          # a subquery can carry joins but not preloads, and the filters' `proload`s add both
          |> exclude(:preload)
          |> exclude(:select)
          |> select(1)

        dynamic(exists(matching))
    end
  end

  @doc """
  The experiences a category covers, defaulting to the one its key names.

  What `Bonfire.Social.Activities.experienced_as/2` answers, rather than what a query can select: the same stored `:create` row is a mention to the person it names and nothing in particular to somebody who got it through a circle. A category usually covers one, and covers several where a distinction matters to a reader but not to a preference (a reply and a response).
  """
  def experiences_for(key) do
    # not `e/3`: `experiences: []` means "claims nothing", which is how `other` and `latest` stay out of this lookup
    case category(key) do
      %{experiences: experiences} -> experiences
      _ -> [key]
    end
  end

  @doc """
  Which category covers this experience, or nil if none declares it.

  The inverse of `experiences_for/1`, so one declaration answers both directions. Exact, unlike guessing from the stored verb, which cannot tell a mention from any other post reaching your feed, nor asking to follow from asking to quote: it is told what the activity was for the person being notified.

  Answers nil rather than `other` for anything undeclared, so the caller decides: a preference reads its catch-all switch, while a chip has nothing to show. That is also what lets an experience arrive that no category has been written for yet.
  """
  def category_for(experience) do
    Enum.find_value(categories(), fn {key, _category} ->
      if experience in experiences_for(key), do: key
    end)
  end

  @doc """
  The icon for an experience: what its category declares, else the verb the category's key names, else the verb the experience itself names.

  One resolution for the chip bar and the notification rows, so a kind cannot be a fire in one place and a heart in the other. Nothing is declared here: the icons live on the categories (`Bonfire.Social.RuntimeConfig`) and on the verbs (`Bonfire.Boundaries.RuntimeConfig`).
  """
  def icon_for(experience, fallback_verb \\ nil) do
    key = category_for(experience) || experience

    e(category(key), :icon, nil) || e(Verbs.get(key), :icon, nil) ||
      e(Verbs.get(experience), :icon, nil) || e(Verbs.get(fallback_verb), :icon, nil)
  end

  @doc """
  The colour a surface gives that icon, as the category declares it, else the neutral one.

  Declared rather than written into each template, so a kind looks the same wherever it appears, and most kinds declare nothing because most are not worth colouring. A class named only here has to appear in the `@source inline(...)` list in `bonfire_ui_common/assets/css/app.css` if it is used nowhere else, since Tailwind scans templates and `*_live.ex` and never reads config.
  """
  def icon_class_for(experience, default \\ "text-primary") do
    case category_for(experience) || experience do
      nil -> default
      key -> e(category(key), :icon_class, nil) || default
    end
  end

  @doc """
  What a row says happened: "liked your activity", "mentioned you", "requested to follow you".

  Declared by the category that covers the experience, so one sentence serves the notification row, a push body and a digest line. `nil` for a kind with no phrase, and the caller shows the plain word instead ("alice wrote").

  `object_id` and `current_user_id` decide between a pair like `%{self: "followed you", other: "followed"}`, which is the only thing the wording turns on beyond the kind itself.

  Translated here rather than where it was declared: `config/0` runs at boot under the default locale, so what it holds is the msgid.
  """
  def phrase_for(experience, object_id \\ nil, current_user_id \\ nil) do
    case category_for(experience) do
      nil ->
        nil

      key ->
        e(category(key), :phrases, %{})
        |> Map.get(experience)
        |> case do
          %{self: self_phrase, other: other_phrase} ->
            if object_id && object_id == current_user_id, do: self_phrase, else: other_phrase

          phrase ->
            phrase
        end
        |> case do
          phrase when is_binary(phrase) -> localise_dynamic(phrase, __MODULE__)
          _ -> nil
        end
    end
  end

  @doc """
  What a Mastodon client calls this experience, or nil for something its vocabulary has no name for.

  Declared per category, since that is the grouping Mastodon's types line up with, and several of ours share one of theirs: a reply and a mention are both `mention` to a client, a like and an emoji reaction are both `favourite`. A category covering kinds that Mastodon names apart declares a map by experience instead, the way `phrases:` does.
  """
  def masto_type_for(experience) do
    case category_for(experience) do
      nil ->
        nil

      key ->
        case e(category(key), :masto, nil) do
          %{} = by_experience -> Map.get(by_experience, experience)
          masto_type -> masto_type
        end
    end
  end

  @doc "Every Mastodon type a category declares, whether one for the category or one per experience."
  def masto_types_of(key) do
    case e(category(key), :masto, nil) do
      nil -> []
      %{} = by_experience -> Map.values(by_experience)
      masto_type -> [masto_type]
    end
  end

  # replaced by the Mastodon adapter mapping its types to category keys (`GraphQLMasto.Notifications`) and the `notification_categories` filter: a category's verbs are not what it selects, so `mention` meant every non-reply post rather than what names you
  # def activity_types_for_masto_type(masto_type) do
  #   categories()
  #   |> Enum.filter(fn {_key, category} -> e(category, :masto, nil) == masto_type end)
  #   |> Enum.flat_map(fn {key, _category} -> activity_types_for(key) end)
  #   |> Enum.uniq()
  # end

  @doc """
  Whether several of these collapse into one row ("A, B and 1 other") rather than getting a row each.

  Declared per category, since it is a property of the kind: a hundred likes are one thing that happened to you, a hundred replies are a hundred.
  """
  def aggregate?(experience) do
    case category_for(experience) do
      nil -> false
      key -> e(category(key), :aggregate, false) == true
    end
  end

  @doc "A category's plural label: what it declares, else the verb's own (singular) name, else its key."
  def label_for(key) do
    e(category(key), :name_pluralized, nil) || e(Verbs.get(key), :verb, nil) || to_string(key)
  end

  @doc """
  Whether a category appears on a surface (`:chip` or `:row`) for the current reader.

  `:unimplemented` entries are declared so their shape is visible, and render only while the
  instance shows unbuilt UI.
  """
  def shown?(key, surface) do
    case e(category(key), surface, true) do
      :unimplemented -> Utils.show_unimplemented?()
      shown? -> shown? != false
    end
  end

  @doc "Categories shown on a surface (`:chip` or `:row`), in display order."
  def categories_shown(surface) do
    Enum.filter(categories(), fn {key, _category} -> shown?(key, surface) end)
  end

  @doc "Whether a category's surface is wired, rather than declared to show its shape."
  def implemented?(key, surface), do: e(category(key), surface, true) == true

  @doc "The settings key holding whether a category appears in this user's notifications feed."
  def show_in_centre_key(key), do: [:notifications, :centre, key]

  @doc "Whether this user wants a category in their notifications feed. On unless they said otherwise."
  def show_in_centre?(key, context \\ nil) do
    Settings.get(show_in_centre_key(key), true, context)
  end

  @doc "Whether this user switched a category out of their notifications feed."
  def hidden_from_centre?(key, context \\ nil), do: show_in_centre?(key, context) == false

  @doc """
  Applies this user's hidden categories to a set of feed filters, for any reader of the feed.

  Called once, where a notifications read resolves its preset (`FeedLoader`), so the LiveView, the GraphQL API and anything else answer the same way. 
  Filters come back untouched for any other feed, for a reader with no user, and when the caller passes `include_hidden: true`, which is how the Mastodon adapter keeps its own semantics (kinds are per request there, nothing stored). 
  Types the caller named explicitly outrank the preference, and a caller's own exclusions are added to rather than replaced.
  """
  def exclude_hidden_categories(filters, opts) do
    if (Types.maybe_to_atom(e(filters, :feed_name, nil)) == :notifications and
          Utils.current_user_id(opts)) && !e(opts, :include_hidden, false) do
      case hidden_categories(opts, List.wrap(e(filters, :activity_types, []))) do
        [] ->
          filters

        hidden ->
          Map.put(
            filters,
            :exclude_notification_categories,
            Enum.uniq(List.wrap(e(filters, :exclude_notification_categories, []) || []) ++ hidden)
          )
      end
    else
      filters
    end
  end

  @doc """
  The categories this user switched off, as a feed `exclude_notification_categories` value, so each is hidden as exactly what its chip shows (`query_filters_for/2`) rather than as its verbs.

  Only rows that are wired are consulted, so an `:unimplemented` row never contributes a filter term.

  `showing` is what the reader asked for explicitly (a category's own chip, an API query naming types), and outranks the switches, since that view is the way back to a category the feed hides: a category whose verbs the reader asked for is not hidden.
  """
  def hidden_categories(context \\ nil, showing \\ []) do
    # config declares verbs as atoms and `showing` comes from a feed filter or a query, which allows either, so both sides meet as strings rather than paying for atom lookups
    asked_for = Enum.map(showing, &to_string/1)

    categories()
    |> Enum.filter(fn {key, category} ->
      e(category, :row, true) == true and hidden_from_centre?(key, context)
    end)
    |> Enum.reject(fn {key, _category} ->
      Enum.any?(activity_types_for(key), &(to_string(&1) in asked_for))
    end)
    |> Enum.map(fn {key, _category} -> key end)
  end

  # replaced by `hidden_categories/2`: hiding a category by its verbs hid every reply when "Replies (without mentioning you)" was off, mentions included, and left replies that name you when Mentions was off
  # def excluded_activity_types(context \\ nil, showing \\ []) do
  #   asked_for = Enum.map(showing, &to_string/1)
  #
  #   case categories()
  #        |> Enum.filter(fn {key, category} ->
  #          e(category, :row, true) == true and hidden_from_centre?(key, context)
  #        end)
  #        |> Enum.flat_map(fn {key, _category} -> activity_types_for(key) end)
  #        |> Enum.uniq()
  #        |> Enum.reject(&(to_string(&1) in asked_for)) do
  #     [] -> false
  #     excluded -> excluded
  #   end
  # end
end
