require 'net/http'
require "uri"
require 'multi_json'

# https://developer.spotify.com/
class SpotifyService

	SPOTIFY_MAX_LIMIT = 50
	SPOTIFY_MAX_LIMIT_TRACKS = 100

	PLAYLIST_NAME = 'Remove from Spotify'

	attr_reader :base_url, :headers, :token, :spotify_id

	def initialize(token, spotify_id)
		@base_url = 'https://api.spotify.com/v1/'
		@token = token
		@spotify_id = spotify_id
		@headers = {
			'Authorization' => "Bearer #{@token}",
			'Content-Type' => 'application/json'
		}
	end

	def playlists
		results = paginate(SPOTIFY_MAX_LIMIT) do |offset|
			params = {
				limit: SPOTIFY_MAX_LIMIT,
				offset: offset	
			}
			request(:get, "users/#{@spotify_id}/playlists", params)
		end

		results.delete_if {|x| x['owner']['id'] != self.spotify_id }
		results
	end

	def create_playlist
		params = {
			name: PLAYLIST_NAME,
			public: false
		}
		request(:post, "users/#{@spotify_id}/playlists", params)
	end

	# Use only to get the snapshot_id
	def playlist(playlist_id)
		request(:get, "users/#{@spotify_id}/playlists/#{playlist_id}")
	end

	def delete_playlist(playlist_id)
		request(:delete, "users/#{@spotify_id}/playlists/#{playlist_id}/followers")
	end

	def tracks(playlist_id)
		paginate(SPOTIFY_MAX_LIMIT_TRACKS) do |offset|
			params = {
				limit: SPOTIFY_MAX_LIMIT_TRACKS,
				offset: offset
			}
			request(:get, "users/#{@spotify_id}/playlists/#{playlist_id}/tracks", params)
		end
	end

	def tracks_from_saved_tracks
		paginate(SPOTIFY_MAX_LIMIT_TRACKS) do |offset|
			params = {
				limit: SPOTIFY_MAX_LIMIT_TRACKS,
				offset: offset	
			}
			request(:get, "me/tracks", params)
		end
	end

	def delete_tracks(playlists, tracks)
		local_tracks, tracks = tracks.partition { |x| x['is_local'] }
		tracks_groups = tracks.each_slice(SPOTIFY_MAX_LIMIT_TRACKS).to_a

		for tracks_to_remove in tracks_groups
			for playlist in playlists
				playlist_id = playlist['id']
				params = {
					tracks: tracks_to_remove.map {|x| { uri: x['track']['uri'] } }
				}
				request(:delete, "users/#{@spotify_id}/playlists/#{playlist_id}/tracks", params)
			end
		end

		delete_local_tracks(playlists, local_tracks)
	end

	# local tracks can be removed like normal tracks
	# https://developer.spotify.com/web-api/local-files-spotify-playlists/
	def delete_local_tracks(playlists, tracks)
		return if tracks.empty?

		tracks_uri = tracks.map {|x| x['track']['uri'] }

		for playlist in playlists
			playlist_id = playlist['id']
			snapshot_id = playlist['snapshot_id']
			playlist_tracks = tracks(playlist_id)
			playlist_tracks.delete_if { |x| !x['is_local'] }

			positions_to_remove = playlist_tracks.each_index.select { |index| tracks_uri.include?(playlist_tracks[index]['track']['uri']) }
			if !positions_to_remove.empty?
				params = {
					snapshot_id: snapshot_id,
					positions: positions_to_remove
				}
				request(:delete, "users/#{@spotify_id}/playlists/#{playlist_id}/tracks", params)
			end
		end
	end

	def delete_tracks_from_saved_tracks(tracks)
		local_tracks, tracks = tracks.partition { |x| x['is_local'] }
		tracks_groups = tracks.each_slice(SPOTIFY_MAX_LIMIT).to_a

		for tracks_to_remove in tracks_groups
			params = {
				ids: tracks_to_remove.map {|x| x['track']['id'] }
			}
			request(:delete, "me/tracks", params)
		end
	end

	def add_tracks(playlist_id, tracks_uri)
		groups_tracks_to_add_uri = tracks_uri.each_slice(SPOTIFY_MAX_LIMIT_TRACKS).to_a

		for tracks_to_add_uri in groups_tracks_to_add_uri
			params = {
				uris: tracks_to_add_uri
			}
			request(:post, "users/#{@spotify_id}/playlists/#{playlist_id}/tracks", params)
		end
	end

	# Merge playlist with the name `PLAYLIST_NAME`
	def fix_duplicates(duplicate_playlists = nil)
		duplicate_playlists ||= playlists.keep_if {|p| p['name'] == PLAYLIST_NAME }
		return nil if duplicate_playlists.size < 2

		playlist = duplicate_playlists.pop
		tracks_uri_to_merge = []

		for duplicate_playlist in duplicate_playlists
			tracks_uri_to_merge += tracks(duplicate_playlist['id']).map {|x| x['track']['uri'] }
		end

		add_tracks(playlist['id'], tracks_uri_to_merge)
		duplicate_playlists.each {|p| delete_playlist(p['id']) }

		playlist
	end

private

	def paginate(limit, &block)
		collection = []
		offset = 0

		result = yield(offset)

		# request error
		return collection if !result

		return collection if result['total'] == 0
		collection += result['items']
		continue = !result['next'].nil?

		if continue
			begin
				offset += limit
				result = yield(offset)

				# request error
				break if !result

				collection += result['items']
				continue = !result['next'].nil?
			end while continue
		end

		collection
	end

	def request(method, path, params = {}, no_retry = false)
		Rails.logger.debug "[SpotifyService] request: method: #{method} - path: #{path} - params: #{params}"

		uri = URI.parse(@base_url)
		http = Net::HTTP.new(uri.host, uri.port)
		http.use_ssl = uri.scheme == 'https'

		url = URI.join(base_url, path)

		case method
		when :get
			url.query = URI.encode_www_form(params)
			response = http.get(url, @headers)
		when :post
			response = http.post(url, MultiJson.dump(params), @headers)
		when :put
			response = http.put(url, MultiJson.dump(params), @headers)
		when :delete
			request = Net::HTTP::Delete.new(url, @headers)
			request.body = MultiJson.dump(params)

			response = http.request(request)
		else
			raise "Invalid method: #{method}"
		end

		if response.is_a?(Net::HTTPSuccess)
			if response.body.blank?
				return nil
			else
				return MultiJson.load(response.body)
			end
		end

		json = begin
			MultiJson.load(response.body)
		rescue StandardError
			{}
		end
		
		if json.is_a?(Hash)
			# Rate Limit
			if json.dig('error', 'status') == 429
				Rails.logger.error "[SpotifyService] request error: Rate Limit #{response['Retry-After']}"

				if no_retry == false
					retry_seconds = response['Retry-After'].to_i
					if retry_seconds > 0
						sleep retry_seconds
					else
						sleep 2
					end

					return request(method, path, params, true)
				end

				# Don't send exception for Rate-Limit
				return nil
			elsif json['error']
				data = { 
					spotify_id: self.spotify_id,
					method: method,
					path: path,
					params: params,
					json: json
				}

				Rails.logger.error "[SpotifyService] request error: #{data.map {|k,v| "#{k}: #{v.inspect}" }.join(' - ')}"
				Raven.capture_exception("[SpotifyService] request error: #{json['error']['message']}", extra: data)

				return nil
			end
		end

		json
	end

end