import Config

config :bonfire_social,
  enabled: true,
  localisation_path: "priv/localisation"

config :paper_trail, repo: Bonfire.Common.Repo

config :paper_trail,
  item_type: Pointers.ULID,
  originator_type: Pointers.ULID,
  originator_relationship_options: [references: :id],
  originator: [name: :user, model: Bonfire.Data.Identity.User]
