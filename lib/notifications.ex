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

  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Common.Types
  alias Bonfire.Common.Utils

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

  Both the chip that shows a category and the switch that hides it read this, so the two can never
  disagree, including approximations (Mentions is `:create` until a filter can ask whether a tag points at you).
  """
  def activity_types_for(key) do
    # not `e/3`, which reads an empty list as nothing set, while `activity_types: []` means "every type" for the default category
    case category(key) do
      %{activity_types: types} -> types
      _ -> [key]
    end
  end

  @doc """
  Which category covers activities of this type, or nil if none declares it.

  The inverse of `activity_types_for/1`, so one declaration answers both directions and a chip and a switch can never disagree about what they cover.

  A category is a grouping people are shown and choose by, not a verb: what it *means* can be narrower than the types it covers, and deciding it properly takes more than an activity type. Mentions is the clearest case, since it means "something addressed me" while all it can filter on today is `create`, so an announcement lands in it too; answering it needs the recipient ("does a tag point at me"). The object can matter as much as the verb: a direct message is a `create` of a `Message`, which is why `Bonfire.Notify.Content` already overrides the verb by object type to tell a DM from a post.

  So this is an approximation, and it is the same one the feed's own chips and switches make, so they move together. The exact answer is the recipient-relative verb Phase 1 adds, and this reads whatever it is told either way.

  Excludes the catch-all (`other`) and the everything category (`latest`): a caller that wants "nothing covers this" should see nil and decide, rather than be handed a key whose filter means something else.
  """
  def category_for_activity_type(activity_type) do
    Enum.find_value(categories(), fn {key, _category} ->
      types = activity_types_for(key)

      if types != [] and activity_type in types, do: key
    end)
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
  def exclude_hidden_types(filters, opts) do
    if (Types.maybe_to_atom(e(filters, :feed_name, nil)) == :notifications and
          Utils.current_user_id(opts)) && !e(opts, :include_hidden, false) do
      case excluded_activity_types(opts, List.wrap(e(filters, :activity_types, []))) do
        false ->
          filters

        excluded ->
          Map.put(
            filters,
            :exclude_activity_types,
            Enum.uniq(List.wrap(e(filters, :exclude_activity_types, []) || []) ++ excluded)
          )
      end
    else
      filters
    end
  end

  @doc """
  The activity types this user switched off, as a feed `exclude_activity_types` value.

  `false` when nothing is off, which is what the `:notifications` preset uses to mean "exclude
  nothing". Only categories with something to exclude are consulted, so an `:unimplemented` row
  never contributes a filter term.

  `showing` is what the reader asked for explicitly (a category's own chip, an API query naming
  types), and outranks the switches, since that view is the way back to a category the feed hides.
  """
  def excluded_activity_types(context \\ nil, showing \\ []) do
    # config declares verbs as atoms and `showing` comes from a feed filter or a query, which allows either, so both sides meet as strings rather than paying for atom lookups
    asked_for = Enum.map(showing, &to_string/1)

    case categories()
         |> Enum.filter(fn {key, category} ->
           e(category, :row, true) == true and hidden_from_centre?(key, context)
         end)
         |> Enum.flat_map(fn {key, _category} -> activity_types_for(key) end)
         |> Enum.uniq()
         |> Enum.reject(&(to_string(&1) in asked_for)) do
      [] -> false
      excluded -> excluded
    end
  end
end
