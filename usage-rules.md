# Bonfire.Social Usage Rules

Bonfire.Social is the core social networking extension implementing activity streams, social interactions, feeds, threading, and federation. These rules ensure correct and efficient usage of this foundational library.

## Core Concepts

### Activities

Activities represent actions taken by subjects (users) on objects using verbs:

```elixir
# Activity structure: {subject, verb, object}
# Example: "Alice liked Bob's post"

activity = %Bonfire.Data.Social.Activity{
  subject: user,           # Who performed the action
  verb: :like,            # What action was performed  
  object: post,           # What was acted upon
  context: thread         # Optional context (e.g., thread)
}
```

### Creating Activities

Use the Activities module to create and manage activities:

```elixir
# Create an activity for any verb
{:ok, activity} = Activities.create(user, :post, post)
{:ok, activity} = Activities.create(user, :follow, target_user)

# With custom options
{:ok, activity} = Activities.create(user, :announce, post, 
  boundary: "public",
  to_feeds: [community.id],
  context: thread
)
```

### Objects Management

Use Objects module for consistent object handling:

```elixir
# Read an object with proper preloading
{:ok, object} = Objects.read(object_id, 
  current_user: user,
  preload: :with_creator
)

# Cast an object (creates activity + handles federation/feeds)
{:ok, object} = Objects.cast(user, %{
  post_content: %{html_body: "Hello world"},
  boundary: "public"
})

# Delete with cascading social cleanup
{:ok, _} = Objects.delete(object, current_user: user)
```

## Epics Pattern (Acts)

Business logic is organized into composable Acts that run in sequence:

```elixir
# Define an Epic with multiple Acts
epic = %Bonfire.Epics.Epic{
  acts: [
    {Bonfire.Social.Acts.PostContentsAct, []},
    {Bonfire.Social.Acts.ActivityAct, []},
    {Bonfire.Social.Acts.ThreadedAct, []},
    {Bonfire.Social.Acts.FederateAct, []},
    {Bonfire.Social.Acts.LivePushAct, []}
  ]
}

# Run the epic
Bonfire.Epics.run(epic, %{
  current_user: user,
  attrs: %{post_content: %{html_body: "Hello"}}
})
```

### Key Acts

- **ActivityAct** - Creates activities for objects
- **FederateAct** - Handles ActivityPub federation
- **LivePushAct** - Pushes real-time updates
- **ThreadedAct** - Manages threading/replies
- **SensitivityAct** - Handles content warnings
- **AntiSpamAct** - Spam detection

## Feed System

### Publishing to Feeds

Activities are automatically published to relevant feeds:

```elixir
# Explicit feed targeting
Activities.create(user, :post, post,
  to_feeds: [user.id, community.id],
  to_circles: [followers_circle_id]
)

# Feed targeting based on boundaries
Objects.cast(user, %{
  post_content: %{html_body: "Public post"},
  boundary: "public"  # Goes to instance feed
})
```

### Reading Feeds

Use FeedActivities for paginated feed reading:

```elixir
# Basic feed query
feed = FeedActivities.feed(:local, current_user: user)

# With filters
feed = FeedActivities.feed({:my, :posts}, 
  current_user: user,
  exclude_verbs: [:like, :boost],
  limit: 20
)

# Custom feed
feed = FeedActivities.feed(community.id,
  current_user: user,
  object_type: Bonfire.Data.Social.Post
)
```

### Feed Presets

Use predefined feed configurations:

```elixir
# Available presets
:my              # User's home feed
:local           # Instance-wide feed  
:activity        # All activities
:explore         # Discovery feed
{:my, :likes}    # User's likes
{:user, user_id} # Specific user's feed
```

## Social Interactions

### Likes

Consistent like/unlike pattern:

```elixir
# Like an object
{:ok, like} = Likes.like(user, object)

# Check if liked
liked? = Likes.liked?(user, object)

# Unlike
{:ok, _} = Likes.unlike(user, object)

# List likes with pagination
likes = Likes.list_likes(object, current_user: user, limit: 20)
```

### Boosts (Reshares)

Boost content to your followers:

```elixir
# Boost an object
{:ok, boost} = Boosts.boost(user, object)

# Check if boosted
boosted? = Boosts.boosted?(user, object)

# Unboost
{:ok, _} = Boosts.unboost(user, object)

# Get boost count
count = Boosts.count(object)
```

### Bookmarks

Private bookmarking:

```elixir
# Bookmark for later
{:ok, bookmark} = Bookmarks.bookmark(user, object)

# List user's bookmarks
bookmarks = Bookmarks.list_my(current_user: user)

# Remove bookmark
{:ok, _} = Bookmarks.unbookmark(user, object)
```

### Flags (Reports)

Content moderation:

```elixir
# Flag inappropriate content
{:ok, flag} = Flags.flag(user, object, 
  reason: "spam",
  message: "Promotional content"
)

# List flags for moderators
flags = Flags.list(current_user: admin_user)
```

## Threading

Manage threaded conversations:

```elixir
# Create a reply
{:ok, reply} = Objects.cast(user, %{
  post_content: %{html_body: "Great post!"},
  reply_to: parent_post,
  context: thread
})

# Get thread participants
participants = Threads.list_participants(thread, 
  current_user: user
)

# List replies
replies = Threads.list_replies(parent_post,
  current_user: user,
  limit: 50
)
```

## Live Updates

Real-time updates via PubSub:

```elixir
# Subscribe to updates in LiveView
def mount(_params, _session, socket) do
  if connected?(socket) do
    PubSub.subscribe("feed:#{socket.assigns.current_user.id}")
  end
  {:ok, socket}
end

# Handle live updates
def handle_info({:new_activity, activity}, socket) do
  {:noreply, 
    socket
    |> assign(:activities, [activity | socket.assigns.activities])
    |> put_flash(:info, "New activity received")
  }
end
```

## Federation (ActivityPub)

### Outgoing Federation

Activities automatically federate based on boundaries:

```elixir
# Public post (federates)
Objects.cast(user, %{
  post_content: %{html_body: "Hello fediverse!"},
  boundary: "public"
})

# Local-only post (doesn't federate)
Objects.cast(user, %{
  post_content: %{html_body: "Local only"},
  boundary: "local"
})
```

### Incoming Activities

Handle incoming ActivityPub activities:

```elixir
# Process incoming activity
APActivities.receive(%{
  "type" => "Create",
  "actor" => remote_actor_uri,
  "object" => %{"content" => "Hello!"}
})
```

## Performance Guidelines

### Efficient Preloading

Use appropriate preload options:

```elixir
# Preload common associations
Activities.activity_with_object_with_preloads(activity,
  skip: [:too_many],
  preload: :with_creator
)

# Custom preloading
FeedActivities.feed(:local,
  current_user: user,
  preload: [
    :with_subject,
    :with_media,
    object: [created: [:profile]]
  ]
)
```

### Pagination

Always paginate large result sets:

```elixir
# Using before/after for cursor pagination
feed = FeedActivities.feed(:local,
  current_user: user,
  after: last_activity_id,
  limit: 20
)

# Page-based pagination
activities = Activities.list(
  page: 2,
  limit: 50
)
```

### Caching

Leverage built-in caching:

```elixir
# Object caching happens automatically
{:ok, object} = Objects.read(id, current_user: user)

# Cache invalidation on updates
Objects.update(object, attrs, invalidate_cache: true)
```

## Testing Patterns

Use provided test helpers:

```elixir
use Bonfire.Social.DataCase

test "user can like a post", %{} do
  user = fake_user!()
  post = fake_post!(user)
  
  assert {:ok, like} = Likes.like(user, post)
  assert Likes.liked?(user, post)
end

test "feed shows relevant activities" do
  alice = fake_user!()
  bob = fake_user!()
  post = fake_post!(alice, %{boundary: "public"})
  
  # Bob's feed should show Alice's post
  feed = FeedActivities.feed(:my, current_user: bob)
  assert Enum.any?(feed.edges, &(&1.activity.object_id == post.id))
end
```

## Common Anti-Patterns to Avoid

### ❌ Direct Activity Creation
```elixir
# Bad - bypasses feeds and federation
Repo.insert(%Activity{verb: :like})

# Good - use Activities module
Activities.create(user, :like, object)
```

### ❌ Manual Feed Insertion
```elixir
# Bad - breaks feed consistency
Repo.insert(%FeedPublish{})

# Good - let Activities handle it
Activities.create(user, :post, object, to_feeds: [feed_id])
```

### ❌ Ignoring Boundaries
```elixir
# Bad - shows private content
Objects.list()

# Good - always pass current_user
Objects.list(current_user: user)
```

### ❌ N+1 Queries
```elixir
# Bad - loads associations lazily
Enum.map(activities, fn a -> a.object.created.profile.name end)

# Good - preload needed associations
Activities.list(preload: [object: [created: :profile]])
```

## Security Considerations

- **Always pass current_user** to respect boundaries
- **Validate verbs** against allowed list
- **Sanitize content** before storing
- **Check permissions** before social actions
- **Rate limit** interactions to prevent spam
- **Validate federation** sources

## Migration Patterns

When adding new social features:

```elixir
defmodule MyApp.Socials.Hearts do
  use Bonfire.Common.Utils
  alias Bonfire.Social.Edges

  def heart(user, object) do
    Edges.changeset(:heart, user, object, current_user: user)
    |> Edges.insert()
  end

  def unheart(user, object) do
    Edges.delete_by_both(user, object, :heart)
  end

  def hearts_count(object) do
    Edges.count(:heart, object)
  end
end
```

## Debugging Tips

```elixir
# Enable debug logging
config :bonfire, Bonfire.Social, debug: true

# Inspect feed targeting
{:ok, activity} = Activities.create(user, :post, object, 
  return: :assigns
)
IO.inspect(activity.assigns[:to_feeds], label: "Target feeds")

# Check federation status
APActivities.federated?(activity)
```

## Extension Integration

Register your extension's verbs and types:

```elixir
# In your extension's config
config :bonfire_social, verbs: [
  heart: "Hearted",
  star: "Starred"
]

config :bonfire_social, object_types: [
  MyApp.Review,
  MyApp.Event
]
```