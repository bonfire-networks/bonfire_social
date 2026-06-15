defmodule Bonfire.Social.Events.Categories do
  @moduledoc """
  The FEP-8a8e event `category` vocabulary (controlled keys + normalisation),
  shared by federation, the event APIs, indexing and the `/events` UI. Display
  concerns (labels, icons, colours) live in the UI layer. See
  https://w3id.org/fep/8a8e.
  """

  # ordered popular-first (also drives the UI's "Browse by Category" grid order)
  @keys ~w(
    MUSIC ARTS FOOD_DRINK PARTY FESTIVALS COMMUNITY MEETING MOVEMENTS_POLITICS
    SPORTS LEARNING SCIENCE_TECH FILM_MEDIA PERFORMING_VISUAL_ARTS THEATRE GAMES
    NETWORKING BUSINESS CAUSES CLIMATE_ENVIRONMENT MEDITATION_WELLBEING
    OUTDOORS_ADVENTURE FAMILY_EDUCATION LANGUAGE_CULTURE LGBTQ INCLUSIVE_SPACES
    CRAFTS CREATIVE_JAM DIY_MAKER_SPACES WORKSHOPS_SKILL_SHARING FASHION_BEAUTY
    PHOTOGRAPHY BOOK_CLUBS COMEDY PETS SPIRITUALITY_RELIGION_BELIEFS AUTO_BOAT_AIR
  )

  @doc "All known category keys, in display order."
  def all, do: @keys

  @doc "Whether a (normalised) key is part of the known vocabulary."
  def known?(key) when is_binary(key), do: key in @keys
  def known?(_), do: false

  @doc "Normalise a category value to the controlled form (UPPER_SNAKE), or nil."
  def normalize(category) when is_binary(category) do
    case category |> String.trim() |> String.upcase() |> String.replace([" ", "-"], "_") do
      "" -> nil
      key -> key
    end
  end

  def normalize(_), do: nil

  @doc "Normalised, de-duplicated categories from an AS2 `Event` map (flat or nested)."
  def from_object(json) when is_map(json) do
    (object_field(json, "category") || object_field(json, "https://w3id.org/fep/8a8e/category"))
    |> List.wrap()
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def from_object(_), do: []

  defp object_field(json, field) do
    get_in(json, ["object", field]) || Map.get(json, field)
  end
end
