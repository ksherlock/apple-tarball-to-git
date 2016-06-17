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

URL_BASE = "http://opensource.apple.com/tarballs/"

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

ok = system('git', 'init', '--bare', git_dir)

# 2. get the tarballs...

url = "#{URL_BASE}#{target}/"
tmpdir = Dir.mktmpdir


files = ls_url(url)

files.each {|file|

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

