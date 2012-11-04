module ActiveRecord
  module Acts #:nodoc:
    module List #:nodoc:
      def self.included(base)
        base.extend(ClassMethods)
      end

      # This +acts_as+ extension provides the capabilities for sorting and reordering a number of objects in a list.
      # The class that has this specified needs to have a +slot+ column defined as an integer on
      # the mapped database table.
      #
      # Todo list example:
      #
      #   class TodoList < ActiveRecord::Base
      #     has_many :todo_items, :order => "slot"
      #   end
      #
      #   class TodoItem < ActiveRecord::Base
      #     belongs_to :todo_list
      #     acts_as_list :scope => :todo_list
      #   end
      #
      #   todo_list.first.move_to_bottom
      #   todo_list.last.move_higher
      module ClassMethods
        # Configuration options are:
        #
        # * +column+ - specifies the column name to use for keeping the slot integer (default: +slot+)
        # * +scope+ - restricts what is to be considered a list. Given a symbol, it'll attach <tt>_id</tt>
        #   (if it hasn't already been added) and use that as the foreign key restriction. It's also possible
        #   to give it an entire string that is interpolated if you need a tighter scope than just a foreign key.
        #   Example: <tt>acts_as_list :scope => 'todo_list_id = #{todo_list_id} AND completed = 0'</tt>
        # * +top_of_list+ - defines the integer used for the top of the list. Defaults to 1. Use 0 to make the collection
        #   act more like an array in its indexing.
        # * +add_new_at+ - specifies whether objects get added to the :top or :bottom of the list. (default: +bottom+)
        def acts_as_list(options = {})
          configuration = { :column => "slot", :scope => "1 = 1", :top_of_list => 1, :add_new_at => :bottom}
          configuration.update(options) if options.is_a?(Hash)

          configuration[:scope] = "#{configuration[:scope]}_id".intern if configuration[:scope].is_a?(Symbol) && configuration[:scope].to_s !~ /_id$/

          if configuration[:scope].is_a?(Symbol)
            scope_condition_method = %(
              def scope_condition
                self.class.send(:sanitize_sql_hash_for_conditions, { :#{configuration[:scope].to_s} => send(:#{configuration[:scope].to_s}) })
              end
            )
          elsif configuration[:scope].is_a?(Array)
            scope_condition_method = %(
              def scope_condition
                attrs = %w(#{configuration[:scope].join(" ")}).inject({}) do |memo,column|
                  memo[column.intern] = send(column.intern); memo
                end
                self.class.send(:sanitize_sql_hash_for_conditions, attrs)
              end
            )
          else
            scope_condition_method = "def scope_condition() \"#{configuration[:scope]}\" end"
          end

          class_eval <<-EOV
            include ::ActiveRecord::Acts::List::InstanceMethods

            def acts_as_list_top
              #{configuration[:top_of_list]}.to_i
            end

            def acts_as_list_class
              ::#{self.name}
            end

            def slot_column
              '#{configuration[:column]}'
            end

            #{scope_condition_method}

            before_destroy :reload_slot
            after_destroy :decrement_slots_on_lower_items
            before_create :add_to_list_#{configuration[:add_new_at]}
            after_update :update_slots
          EOV
        end
      end

      # All the methods available to a record that has had <tt>acts_as_list</tt> specified. Each method works
      # by assuming the object to be the item in the list, so <tt>chapter.move_lower</tt> would move that chapter
      # lower in the list of all chapters. Likewise, <tt>chapter.first?</tt> would return +true+ if that chapter is
      # the first in the list of all chapters.
      module InstanceMethods
        # Insert the item at the given slot (defaults to the top slot of 1).
        def insert_at(slot = acts_as_list_top)
          insert_at_slot(slot)
        end

        # Swap slots with the next lower item, if one exists.
        def move_lower
          return unless lower_item

          acts_as_list_class.transaction do
            lower_item.decrement_slot
            increment_slot
          end
        end

        # Swap slots with the next higher item, if one exists.
        def move_higher
          return unless higher_item

          acts_as_list_class.transaction do
            higher_item.increment_slot
            decrement_slot
          end
        end

        # Move to the bottom of the list. If the item is already in the list, the items below it have their
        # slot adjusted accordingly.
        def move_to_bottom
          return unless in_list?
          acts_as_list_class.transaction do
            decrement_slots_on_lower_items
            assume_bottom_slot
          end
        end

        # Move to the top of the list. If the item is already in the list, the items above it have their
        # slot adjusted accordingly.
        def move_to_top
          return unless in_list?
          acts_as_list_class.transaction do
            increment_slots_on_higher_items
            assume_top_slot
          end
        end

        # Removes the item from the list.
        def remove_from_list
          if in_list?
            decrement_slots_on_lower_items
            update_attributes! slot_column => nil
          end
        end

        # Increase the slot of this item without adjusting the rest of the list.
        def increment_slot
          return unless in_list?
          update_attributes! slot_column => self.send(slot_column).to_i + 1
        end

        # Decrease the slot of this item without adjusting the rest of the list.
        def decrement_slot
          return unless in_list?
          update_attributes! slot_column => self.send(slot_column).to_i - 1
        end

        # Return +true+ if this object is the first in the list.
        def first?
          return false unless in_list?
          self.send(slot_column) == acts_as_list_top
        end

        # Return +true+ if this object is the last in the list.
        def last?
          return false unless in_list?
          self.send(slot_column) == bottom_slot_in_list
        end

        # Return the next higher item in the list.
        def higher_item
          return nil unless in_list?
          acts_as_list_class.unscoped.find(:first, :conditions =>
            "#{scope_condition} AND #{slot_column} = #{(send(slot_column).to_i - 1).to_s}"
          )
        end

        # Return the next lower item in the list.
        def lower_item
          return nil unless in_list?
          acts_as_list_class.unscoped.find(:first, :conditions =>
            "#{scope_condition} AND #{slot_column} = #{(send(slot_column).to_i + 1).to_s}"
          )
        end

        # Test if this record is in a list
        def in_list?
          !not_in_list?
        end

        def not_in_list?
          send(slot_column).nil?
        end

        def default_slot
          acts_as_list_class.columns_hash[slot_column.to_s].default
        end

        def default_slot?
          default_slot == send(slot_column)
        end

        private
          def add_to_list_top
            increment_slots_on_all_items
            self[slot_column] = acts_as_list_top
          end

          def add_to_list_bottom
            if not_in_list? || default_slot?
              self[slot_column] = bottom_slot_in_list.to_i + 1
            else
              increment_slots_on_lower_items(self[slot_column])
            end
          end

          # Overwrite this method to define the scope of the list changes
          def scope_condition() "1" end

          # Returns the bottom slot number in the list.
          #   bottom_slot_in_list    # => 2
          def bottom_slot_in_list(except = nil)
            item = bottom_item(except)
            item ? item.send(slot_column) : acts_as_list_top - 1
          end

          # Returns the bottom item
          def bottom_item(except = nil)
            conditions = scope_condition
            conditions = "#{conditions} AND #{self.class.primary_key} != #{except.id}" if except
            acts_as_list_class.unscoped.find(:first, :conditions => conditions, :order => "#{acts_as_list_class.table_name}.#{slot_column} DESC")
          end

          # Forces item to assume the bottom slot in the list.
          def assume_bottom_slot
            update_attributes!(slot_column => bottom_slot_in_list(self).to_i + 1)
          end

          # Forces item to assume the top slot in the list.
          def assume_top_slot
            update_attributes!(slot_column => acts_as_list_top)
          end

          # This has the effect of moving all the higher items up one.
          def decrement_slots_on_higher_items(slot)
            acts_as_list_class.unscoped.update_all(
              "#{slot_column} = (#{slot_column} - 1)", "#{scope_condition} AND #{slot_column} <= #{slot}"
            )
          end

          # This has the effect of moving all the lower items up one.
          def decrement_slots_on_lower_items(slot=nil)
            return unless in_list?
            slot ||= send(slot_column).to_i
            acts_as_list_class.unscoped.update_all(
              "#{slot_column} = (#{slot_column} - 1)", "#{scope_condition} AND #{slot_column} > #{slot}"
            )
          end

          # This has the effect of moving all the higher items down one.
          def increment_slots_on_higher_items
            return unless in_list?
            acts_as_list_class.unscoped.update_all(
              "#{slot_column} = (#{slot_column} + 1)", "#{scope_condition} AND #{slot_column} < #{send(slot_column).to_i}"
            )
          end

          # This has the effect of moving all the lower items down one.
          def increment_slots_on_lower_items(slot)
            acts_as_list_class.unscoped.update_all(
              "#{slot_column} = (#{slot_column} + 1)", "#{scope_condition} AND #{slot_column} >= #{slot}"
           )
          end

          # Increments slot (<tt>slot_column</tt>) of all items in the list.
          def increment_slots_on_all_items
            acts_as_list_class.unscoped.update_all(
              "#{slot_column} = (#{slot_column} + 1)",  "#{scope_condition}"
            )
          end

          # Reorders intermediate items to support moving an item from old_slot to new_slot.
          def shuffle_slots_on_intermediate_items(old_slot, new_slot, avoid_id = nil)
            return if old_slot == new_slot
            avoid_id_condition = avoid_id ? " AND #{self.class.primary_key} != #{avoid_id}" : ''
            if old_slot < new_slot
              # Decrement slot of intermediate items
              #
              # e.g., if moving an item from 2 to 5,
              # move [3, 4, 5] to [2, 3, 4]
              acts_as_list_class.unscoped.update_all(
                "#{slot_column} = (#{slot_column} - 1)", "#{scope_condition} AND #{slot_column} > #{old_slot} AND #{slot_column} <= #{new_slot}#{avoid_id_condition}"
              )
            else
              # Increment slot of intermediate items
              #
              # e.g., if moving an item from 5 to 2,
              # move [2, 3, 4] to [3, 4, 5]
              acts_as_list_class.unscoped.update_all(
                "#{slot_column} = (#{slot_column} + 1)", "#{scope_condition} AND #{slot_column} >= #{new_slot} AND #{slot_column} < #{old_slot}#{avoid_id_condition}"
              )
            end
          end

          def insert_at_slot(slot)
            if in_list?
              old_slot = send(slot_column).to_i
              return if slot == old_slot
              shuffle_slots_on_intermediate_items(old_slot, slot)
            else
              increment_slots_on_lower_items(slot)
            end
            self.update_attributes!(slot_column => slot)
          end

          # used by insert_at_slot instead of remove_from_list, as postgresql raises error if slot_column has non-null constraint
          def store_at_0
            if in_list?
              old_slot = send(slot_column).to_i
              update_attributes!(slot_column => 0)
              decrement_slots_on_lower_items(old_slot)
            end
          end

          def update_slots
            old_slot = send("#{slot_column}_was").to_i
            new_slot = send(slot_column).to_i
            return unless acts_as_list_class.unscoped.where("#{scope_condition} AND #{slot_column} = #{new_slot}").count > 1
            shuffle_slots_on_intermediate_items old_slot, new_slot, id
          end

          def reload_slot
            self.reload
          end
      end
    end
  end
end
