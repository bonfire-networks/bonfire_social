import Config

config :bonfire_common,
  localisation_path: "priv/localisation"

config :bonfire_social,
  enabled: true

config :paper_trail, repo: Bonfire.Common.Repo

config :paper_trail,
  item_type: Needle.ULID,
  originator_type: Needle.ULID,
  originator_relationship_options: [references: :id],
  originator: [name: :user, model: Bonfire.Data.Identity.User]
