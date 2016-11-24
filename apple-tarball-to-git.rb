#!/usr/bin/env ruby -w

require 'optparse'
require 'nokogiri'
require 'open-uri'
require 'fileutils'
require 'tmpdir'
require 'zlib'

#
# convert opensource.apple.com tarballs into a git repo.
#
#

URL_BASE = "https://opensource.apple.com/tarballs/"

def compare_versions(a,b)

	# name-(version string).tar.gz
	# version may be a simple number or more complex.
	# eg xnu-792.tar.gz and xnu-792.6.76.tar.gz

	a = a.chomp(".tgz").chomp(".gz").chomp(".tar")
	b = b.chomp(".tgz").chomp(".gz").chomp(".tar")
	va = $1.split('.') if a.match( /-([0-9.]+)$/)
	vb = $1.split('.') if b.match( /-([0-9.]+)$/)

	va.reverse!
	vb.reverse!

	while !va.empty? && !vb.empty?
		ta = va.pop.to_i
		tb = vb.pop.to_i
		next if ta == tb
		return ta <=> tb

	end

	return va.count <=> vb.count

end

def ls_url(url)
	# returns a list of the tarballs
	# raises error on 404, etc
	puts "fetching #{url}"

	page = Nokogiri::HTML(open(url))
	return page.css('a') 
	. map { |e|  e['href']} 
	. select {|href| href =~ /\.tar\.gz$/}
	. uniq
	.sort(&method(:compare_versions))
end

def download_url(url, dest)

	puts "fetching #{url}"

	x = open(url)

	data = x.read


	File.open(dest, "w") {|f|

		f.write(data)
	}

	# return the date from the first entry.
	tar = Zlib::GzipReader.new(StringIO.new(data))
	tar.read(100 + 8 + 8 + 8 + 12) # name + mode + owner + group + size

	tmp = tar.read(12) # last mod time, octal format.
	tmp.chomp!("\x00")
	date = tmp.oct #
	return Time.at(date)
end


def get_max_tag(git_dir)

	# check for a tag that matches master, then remove any files <= it.
	master = ""
	tags = {}

	IO.popen(['git', '--git-dir', git_dir, 'show-ref'], "r") {|io|
		io.each_line {|line|
			x = line.match(/^([A-Fa-f0-9]+)\s+(.*)$/)
			if (x)
				hash = x[1]
				name = x[2]
				case name
				when "refs/heads/master"
					master = hash
				when /^refs\/tags\/(.*)$/
					version = $1
					# could be multiple tags with the same hash...
					tags[hash] = [] unless tags[hash]
					tags[hash].push(version)
				end
			end
		}
	}

	return nil if master == "" # ???
	return nil unless tags[master]

	return tags[master].max(&method(:compare_versions))
end




# begin!

config = {
	:tags => true,
	:date => true,
	:author => "Apple <opensource@apple.com>",
	:verbose => false,
	:update => false,
}

OptionParser.new { |opts|

	opts.version = "0.0"
	opts.release = "0.0"

    opts.banner = "Usage: apple-tarball-to-git [options] name"
    
    opts.on('--[no-]date', 'Fudge the commit dates') do |x|
    	config[:date] = x
    end

    opts.on('--[no-]tags', 'Create tags') do |x|
    	config[:tags] = x
    end

    opts.on('--[no-]verbose', 'Be verbose') do |x|
    	config[:verbose] = x
    end

    opts.on('--author [NAME]', String, 'Specify commit author') do |x|
    	config[:author] = x
    end

    opts.on('--no-author', 'Don\'t specify the commit author') do |x|
    	config[:author] = nil
	end

    opts.on('--update', 'Update an existing repository') do |x|
    	config[:update] = true
    end

}.parse!


if (ARGV.length != 1)
	puts "target name is required."
	exit 1
end

target = ARGV.first
git_dir = "#{target}.git"


# 1. create a git repo...


case [config[:update], File.directory?(git_dir) ]
	when [true, false]
		$stderr.puts "git repo does not exist."
		exit 1

	when [false, true]
		$stderr.puts "git repo already exists. use --update to update "
		exit 1

	when [false, false]
		ok = system('git', 'init', '--bare', git_dir)

	when [true, true]
		max_tag = get_max_tag(git_dir)
		if max_tag.nil?
			$stderr.puts "Unable to update repo"
			exit 1
		end
		puts "Updating from #{max_tag}"
end


# 2. get the tarballs...

url = "#{URL_BASE}#{target}/"
tmpdir = Dir.mktmpdir


files = ls_url(url)

files.each {|file|

	# --update -- filter out old tags
	if config[:update]
		next if compare_versions(max_tag, file) >= 0
	end

	url = "#{URL_BASE}#{target}/#{file}"

	local = "#{tmpdir}/#{file}"
	basename = file.chomp(".tar.gz")
	wt = "#{tmpdir}/#{basename}/" # Working Tree

	date = download_url(url, local)

	ok = system('tar', '-x', '-C', tmpdir, '-f', local, '-z')

	git_argv = ['git', '--git-dir', git_dir, '--work-tree', wt]

	ok = system(*git_argv, 'add', '.')


	extra = []
	extra += ['--date', date.to_s] if config[:date]
	extra += ['--author', config[:author]] unless config[:author].nil?

	ok = system(*git_argv, 'commit', '-a', '-m', basename, *extra)
	ok = system('git', '--git-dir', git_dir, 'tag', basename) if config[:tags]

	FileUtils.remove_entry(wt, true)
	FileUtils.remove_entry(local, true)

}

FileUtils.remove_entry tmpdir


exit 0

