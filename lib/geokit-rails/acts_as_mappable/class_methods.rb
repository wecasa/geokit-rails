module Geokit
  module ActsAsMappable

    # Class methods included in models when +acts_as_mappable+ is called
    module ClassMethods

      # A proxy to an instance of a finder adapter, inferred from the connection's adapter.
      def geokit_finder_adapter
        @geokit_finder_adapter ||= begin
                                     unless Adapters.const_defined?(connection.adapter_name.camelcase)
                                       filename = connection.adapter_name.downcase
                                       require File.join("geokit-rails", "adapters", filename)
                                     end
                                     klass = Adapters.const_get(connection.adapter_name.camelcase)
                                     if klass.class == Module
                                       # For some reason Mysql2 adapter was defined in Adapters.constants but was Module instead of a Class
                                       filename = connection.adapter_name.downcase
                                       require File.join("geokit-rails", "adapters", filename)
                                       # Re-init the klass after require
                                       klass = Adapters.const_get(connection.adapter_name.camelcase)
                                     end
                                     klass.load(self) unless klass.loaded || skip_loading
                                     klass.new(self)
                                   rescue LoadError
                                     raise UnsupportedAdapter, "`#{connection.adapter_name.downcase}` is not a supported adapter."
                                   end
      end

      def within(distance, options = {})
        options[:within] = distance
        # Add bounding box to speed up SQL request.
        bounds = formulate_bounds_from_distance(
          options,
          normalize_point_to_lat_lng(options[:origin]),
          options[:units] || default_units)
        with_latlng.where(bound_conditions(bounds)).
          where(distance_conditions(options))
      end
      alias inside within

      def beyond(distance, options = {})
        options[:beyond] = distance
        #geo_scope(options)
        where(distance_conditions(options))
      end
      alias outside beyond

      def in_range(range, options = {})
        options[:range] = range
        #geo_scope(options)
        where(distance_conditions(options))
      end

      def in_bounds(bounds, options = {})
        inclusive = options.delete(:inclusive) || false
        options[:bounds] = bounds
        #geo_scope(options)
        #where(distance_conditions(options))
        bounds  = extract_bounds_from_options(options)
        where(bound_conditions(bounds, inclusive))
      end

      def by_distance(options = {})
        origin  = extract_origin_from_options(options)
        units   = extract_units_from_options(options)
        formula = extract_formula_from_options(options)
        distance_column_name = distance_sql(origin, units, formula)
        with_latlng.order(
          Arel.sql(distance_column_name).send(options[:reverse] ? 'desc' : 'asc')
        )
      end

      def with_latlng
        where("?.? IS NOT NULL AND ?.? IS NOT NULL", table_name, lat_column_name, table_name, lng_column_name)
      end

      def closest(options = {})
        by_distance(options).limit(1)
      end
      alias nearest closest

      def farthest(options = {})
        by_distance({:reverse => true}.merge(options)).limit(1)
      end

      #def geo_scope(options = {})
      #  arel = self.is_a?(ActiveRecord::Relation) ? self : self.scoped

      #  origin  = extract_origin_from_options(options)
      #  units   = extract_units_from_options(options)
      #  formula = extract_formula_from_options(options)
      #  bounds  = extract_bounds_from_options(options)

      #  if origin || bounds
      #    bounds = formulate_bounds_from_distance(options, origin, units) unless bounds

      #    if origin
      #      arel.distance_formula = distance_sql(origin, units, formula)
      #
      #      if arel.select_values.blank?
      #        star_select = Arel::Nodes::SqlLiteral.new(arel.quoted_table_name + '.*')
      #        arel = arel.select(star_select)
      #      end
      #    end

      #    if bounds
      #      bound_conditions = bound_conditions(bounds)
      #      arel = arel.where(bound_conditions) if bound_conditions
      #    end

      #    distance_conditions = distance_conditions(options)
      #    arel = arel.where(distance_conditions) if distance_conditions

      #    if self.through
      #      arel = arel.includes(self.through)
      #    end
      #  end

      #  arel
      #end

      # Returns the distance calculation to be used as a display column or a condition.  This
      # is provide for anyone wanting access to the raw SQL.
      def distance_sql(origin, units=default_units, formula=default_formula)
        case formula
        when :sphere
          sql = sphere_distance_sql(origin, units)
        when :flat
          sql = flat_distance_sql(origin, units)
        end
        sql
      end

      private

      # Override ActiveRecord::Base.relation to return an instance of Geokit::ActsAsMappable::Relation.
      # TODO: Do we need to override JoinDependency#relation too?
      #def relation
      #  # NOTE: This cannot be @relation as ActiveRecord already uses this to
      #  # cache *its* Relation object
      #  @_geokit_relation ||= Relation.new(self, arel_table)
      #  finder_needs_type_condition? ? @_geokit_relation.where(type_condition) : @_geokit_relation
      #end

      # If it's a :within query, add a bounding box to improve performance.
      # This only gets called if a :bounds argument is not otherwise supplied.
      def formulate_bounds_from_distance(options, origin, units)
        distance = options[:within] if options.has_key?(:within) && options[:within].is_a?(Numeric)
        distance = options[:range].last-(options[:range].exclude_end?? 1 : 0) if options.has_key?(:range)
        if distance
          Geokit::Bounds.from_point_and_radius(origin,distance,:units=>units)
        else
          nil
        end
      end

      def distance_conditions(options)
        origin  = extract_origin_from_options(options)
        units   = extract_units_from_options(options)
        formula = extract_formula_from_options(options)
        distance_column_name = distance_sql(origin, units, formula)

        if options.has_key?(:within)
          Arel.sql(distance_column_name).lteq(options[:within])
        elsif options.has_key?(:beyond)
          Arel.sql(distance_column_name).gt(options[:beyond])
        elsif options.has_key?(:range)
          min_condition = Arel.sql(distance_column_name).gteq(options[:range].begin)
          max_condition = if options[:range].exclude_end?
                            Arel.sql(distance_column_name).lt(options[:range].end)
                          else
                            Arel.sql(distance_column_name).lteq(options[:range].end)
                          end
          min_condition.and(max_condition)
        end
      end

      def bound_conditions(bounds, inclusive = false)
        return nil unless bounds
        if inclusive
          lt_operator = :lteq
          gt_operator = :gteq
        else
          lt_operator = :lt
          gt_operator = :gt
        end
        sw,ne = bounds.sw, bounds.ne
        lat, lng = Arel.sql(qualified_lat_column_name), Arel.sql(qualified_lng_column_name)
        lat.send(gt_operator, sw.lat).and(lat.send(lt_operator, ne.lat)).and(
          if bounds.crosses_meridian?
            lng.send(lt_operator, ne.lng).or(lng.send(gt_operator, sw.lng))
          else
            lng.send(gt_operator, sw.lng).and(lng.send(lt_operator, ne.lng))
          end
        )
      end

      # Extracts the origin instance out of the options if it exists and returns
      # it.  If there is no origin, looks for latitude and longitude values to
      # create an origin.  The side-effect of the method is to remove these
      # option keys from the hash.
      def extract_origin_from_options(options)
        origin = options.delete(:origin)
        res = normalize_point_to_lat_lng(origin) if origin
        res
      end

      # Extract the units out of the options if it exists and returns it.  If
      # there is no :units key, it uses the default.  The side effect of the
      # method is to remove the :units key from the options hash.
      def extract_units_from_options(options)
        units = options[:units] || default_units
        options.delete(:units)
        units
      end

      # Extract the formula out of the options if it exists and returns it.  If
      # there is no :formula key, it uses the default.  The side effect of the
      # method is to remove the :formula key from the options hash.
      def extract_formula_from_options(options)
        formula = options[:formula] || default_formula
        options.delete(:formula)
        formula
      end

      def extract_bounds_from_options(options)
        bounds = options.delete(:bounds)
        bounds = Geokit::Bounds.normalize(bounds) if bounds
      end

      # Geocode IP address.
      def geocode_ip_address(origin)
        geo_location = Geokit::Geocoders::MultiGeocoder.geocode(origin)
        return geo_location if geo_location.success
        raise Geokit::Geocoders::GeocodeError
      end

      # Given a point in a variety of (an address to geocode,
      # an array of [lat,lng], or an object with appropriate lat/lng methods, an IP addres)
      # this method will normalize it into a Geokit::LatLng instance. The only thing this
      # method adds on top of LatLng#normalize is handling of IP addresses
      def normalize_point_to_lat_lng(point)
        res = geocode_ip_address(point) if point.is_a?(String) && /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})?$/.match(point)
        res = Geokit::LatLng.normalize(point) unless res
        res
      end

      # Looks for the distance column and replaces it with the distance sql. If an origin was not
      # passed in and the distance column exists, we leave it to be flagged as bad SQL by the database.
      # Conditions are either a string or an array.  In the case of an array, the first entry contains
      # the condition.
      def substitute_distance_in_where_values(arel, origin, units=default_units, formula=default_formula)
        pattern = Regexp.new("\\b#{distance_column_name}\\b")
        value   = distance_sql(origin, units, formula)
        arel.where_values.map! do |where_value|
          if where_value.is_a?(String)
            where_value.gsub(pattern, value)
          else
            where_value
          end
        end
        arel
      end

      # Returns the distance SQL using the spherical world formula (Haversine).  The SQL is tuned
      # to the database in use.
      def sphere_distance_sql(origin, units)
        # "origin" can be a Geokit::LatLng (with :lat and :lng methods), e.g.
        # when using geo_scope or it can be an ActsAsMappable with customized
        # latitude and longitude methods, e.g. when using distance_sql.
        lat = deg2rad(get_lat(origin))
        lng = deg2rad(get_lng(origin))
        multiplier = units_sphere_multiplier(units)
        geokit_finder_adapter.sphere_distance_sql(lat, lng, multiplier) if geokit_finder_adapter
      end

      # Returns the distance SQL using the flat-world formula (Phythagorean Theory).  The SQL is tuned
      # to the database in use.
      def flat_distance_sql(origin, units)
        lat_degree_units = units_per_latitude_degree(units)
        lng_degree_units = units_per_longitude_degree(get_lat(origin), units)
        geokit_finder_adapter.flat_distance_sql(origin, lat_degree_units, lng_degree_units)
      end

      def get_lat(origin)
        origin.respond_to?(:lat) ? origin.lat \
                                 : origin.send(:"#{lat_column_name}")
      end

      def get_lng(origin)
        origin.respond_to?(:lng) ? origin.lng \
                                 : origin.send(:"#{lng_column_name}")
      end

    end # ClassMethods
  end
end
