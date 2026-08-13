class PowensItem::SyncCompleteEvent
  attr_reader :powens_item

  # Build the event for the given +powens_item+.
  def initialize(powens_item)
    @powens_item = powens_item
  end

  # Broadcast sync-complete Turbo updates for the item, its accounts, and family.
  def broadcast
    powens_item.accounts.each(&:broadcast_sync_complete)

    powens_item.broadcast_replace_to(
      powens_item.family,
      target: "powens_item_#{powens_item.id}",
      partial: "powens_items/powens_item",
      locals: { powens_item: powens_item }
    )

    powens_item.family.broadcast_sync_complete
  end
end
