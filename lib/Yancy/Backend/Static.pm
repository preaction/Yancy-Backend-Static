package Yancy::Backend::Static;
our $VERSION = '0.016';
# ABSTRACT: Build a Yancy site from static Markdown files

=head1 SYNOPSIS

    use Mojolicious::Lite;
    plugin Yancy => {
        backend => 'static:.',
        read_schema => 1,
    };
    get '/*slug', {
        controller => 'yancy',
        action => 'get',
        schema => 'pages',
        slug => 'index', # Default to index page
        template => 'default', # default.html.ep below
    };
    app->start;
    __DATA__
    @@ default.html.ep
    % title $item->{title};
    <%== $item->{html} %>

=head1 DESCRIPTION

This L<Yancy::Backend> allows Yancy to work with a site made up of
Markdown files with YAML frontmatter, like a L<Statocles> site. In other
words, this module works with a flat-file database made up of YAML
+ Markdown files.

=head2 Schemas

You should configure the C<pages> schema to have all of the fields
that could be in the frontmatter of your Markdown files. This is JSON Schema
and will be validated, but if you're using the Yancy editor, make sure only
to use L<the types Yancy
supports|https://metacpan.org/pod/Yancy::Guides::Schema#Types>.

=head2 Limitations

This backend should support everything L<Yancy::Backend> supports, though
some list() queries may not work (please make a pull request).

=head2 Future Developments

This backend could be enhanced to provide schema for static files
(CSS, JavaScript, etc...) and templates.

=head1 GETTING STARTED

To get started using this backend to make a simple static website, first
create a file called C<myapp.pl> with the following contents:

    #!/usr/bin/env perl
    use Mojolicious::Lite;
    plugin Yancy => {
        backend => 'static:.',
        read_schema => 1,
    };
    get '/*slug', {
        controller => 'yancy',
        action => 'get',
        schema => 'pages',
        template => 'default',
        layout => 'default',
        slug => 'index',
    };
    app->start;
    __DATA__
    @@ default.html.ep
    % title $item->{title};
    <%== $item->{html} %>
    @@ layouts/default.html.ep
    <!DOCTYPE html>
    <html>
    <head>
        <title><%= title %></title>
        <link rel="stylesheet" href="/yancy/bootstrap.css">
    </head>
    <body>
        <main class="container">
            %= content
        </main>
        <script src="/yancy/jquery.js"></script>
        <script src="/yancy/bootstrap.js"></script>
    </body>
    </html>

Once this is done, run the development webserver using C<perl myapp.pl
daemon>:

    $ perl myapp.pl daemon
    Server available at http://127.0.0.1:3000

Then open C<http://127.0.0.1:3000/yancy> in your web browser to see the
L<Yancy> editor.

=for html <img style="max-width: 100%" src="https://raw.githubusercontent.com/preaction/Yancy-Backend-Static/master/eg/public/editor-1.png">

You should first create an C<index> page by clicking the "Add Item"
button to create a new page and giving the page a C<slug> of C<index>.

=for html <img style="max-width: 100%" src="https://raw.githubusercontent.com/preaction/Yancy-Backend-Static/master/eg/public/editor-2.png">

Once this page is created, you can visit your new page either by
clicking the "eye" icon on the left side of the table, or by navigating
to L<http://127.0.0.1:3000>.

=for html <img style="max-width: 100%" src="https://raw.githubusercontent.com/preaction/Yancy-Backend-Static/master/eg/public/editor-3.png">

=head2 Adding Images and Files

To add other files to your site (images, scripts, stylesheets, etc...),
create a directory called C<public> and put your file in there.  All the
files in the C<public> folder are available to use in your website.

To add an image using Markdown, use C<![](path/to/image.jpg)>.

=head2 Customize Template and Layout

The easiest way to customize the look of the site is to edit the layout
template. Templates in Mojolicious can be in external files in
a C<templates> directory, or they can be in the C<myapp.pl> script below
C<__DATA__>.

The layout your site uses currently is called
C<layouts/default.html.ep>.  The two main things to put in a layout are
C<< <%= title %> >> for the page's title and C<< <%= content %> >> for
the page's content. Otherwise, the layout can be used to add design and
navigation for your site.

=head1 ADVANCED FEATURES

=head2 Custom Metadata Fields

You can add additional metadata fields to your page by adding them to
your schema, like so:

    plugin Yancy => {
        backend => 'static:.',
        read_schema => 1,
        schema => {
            pages => {
                properties => {
                    # Add an optional 'author' field
                    author => { type => [ 'string', 'null' ] },
                },
            },
        },
    };

These additional fields can be used in your template through the
C<$item> hash reference (C<< $item->{author} >>).  See
L<Yancy::Guides::Schema> for more information about configuring a schema.

=head2 Character Encoding

By default, this backend detects the locale of your current environment
and assumes the files you read and write should be in that encoding. If
this is incorrect (if, for example, you always want to read/write UTF-8
files), add a C<?encoding=...> to the backend string:

    use Mojolicious::Lite;
    plugin Yancy => {
        backend => 'static:.?encoding=UTF-8',
        read_schema => 1,
    };

=head1 SEE ALSO

L<Yancy>, L<Statocles>

=cut

use Mojo::Base -base;
use Mojo::File;
use Text::Markdown;
use YAML ();
use JSON::PP ();
use Yancy::Util qw( match order_by );

# Can't use open ':locale' because it caches the current locale (so it
# won't work in tests unless we create a new process with the changed
# locale...)
use I18N::Langinfo qw( langinfo CODESET );
use Encode qw( encode decode );

has schema => sub { +{} };
has path =>;
has markdown_parser => sub { Text::Markdown->new };
has encoding => sub { langinfo( CODESET ) };

sub new {
    my ( $class, $backend, $schema ) = @_;
    my ( undef, $path ) = split /:/, $backend, 2;
    $path =~ s/^([^?]+)\?(.+)$/$1/;
    my %attrs = map { split /=/ } split /\&/, $2 // '';
    return $class->SUPER::new( {
        %attrs,
        path => Mojo::File->new( $path ),
        ( schema => $schema )x!!$schema,
    } );
}

sub create {
    my ( $self, $schema, $params ) = @_;

    my $path = $self->path->child( $self->_id_to_path( $params->{slug} ) );
    $self->_write_file( $path, $params );
    return $params->{slug};
}

sub get {
    my ( $self, $schema, $id ) = @_;

    # Allow directory path to work. Must have a trailing slash to ensure
    # that relative links in the file work correctly.
    if ( $id =~ m{/$} && -d $self->path->child( $id ) ) {
        $id .= 'index.markdown';
    }
    else {
        # Clean up the input path
        $id =~ s/\.\w+$//;
        $id .= '.markdown';
    }

    my $path = $self->path->child( $id );
    #; say "Getting path $id: $path";
    return undef unless -f $path;

    my $item = eval { $self->_read_file( $path ) };
    if ( $@ ) {
        warn sprintf 'Could not load file %s: %s', $path, $@;
        return undef;
    }
    $item->{slug} = $self->_path_to_id( $path->to_rel( $self->path ) );
    $self->_normalize_item( $schema, $item );
    return $item;
}

sub _normalize_item {
    my ( $self, $schema_name, $item ) = @_;
    return unless my $schema = $self->schema->{ $schema_name };
    for my $prop_name ( keys %{ $item } ) {
        next unless my $prop = $schema->{ properties }{ $prop_name };
        if ( $prop->{type} eq 'array' && ref $item->{ $prop_name } ne 'ARRAY' ) {
            $item->{ $prop_name } = [ $item->{ $prop_name } ];
        }
    }
}

sub list {
    my ( $self, $schema, $params, $opt ) = @_;
    $params ||= {};
    $opt ||= {};

    my @items;
    my $total = 0;
    PATH: for my $path ( sort $self->path->list_tree->each ) {
        next unless $path =~ /[.](?:markdown|md)$/;
        my $item = eval { $self->_read_file( $path ) };
        if ( $@ ) {
            warn sprintf 'Could not load file %s: %s', $path, $@;
            next;
        }
        $item->{slug} = $self->_path_to_id( $path->to_rel( $self->path ) );
        $self->_normalize_item( $schema, $item );
        next unless match( $params, $item );
        push @items, $item;
        $total++;
    }

    $opt->{order_by} //= 'slug';
    my $ordered_items = order_by( $opt->{order_by}, \@items );

    my $start = $opt->{offset} // 0;
    my $end = $opt->{limit} ? $start + $opt->{limit} - 1 : $#items;
    if ( $end > $#items ) {
        $end = $#items;
    }

    return {
        items => [ @{$ordered_items}[ $start .. $end ] ],
        total => $total,
    };
}

sub set {
    my ( $self, $schema, $id, $params ) = @_;
    my $path = $self->path->child( $self->_id_to_path( $id ) );
    # Load the current file to turn a partial set into a complete
    # set
    my %item = (
        -f $path ? %{ $self->_read_file( $path ) } : (),
        %$params,
    );

    if ( $params->{slug} ) {
      my $new_path = $self->path->child( $self->_id_to_path( $params->{slug} ) );
      if ( -f $path and $new_path ne $path ) {
         $path->remove;
      }
      $path = $new_path;
    }
    $self->_write_file( $path, \%item );
    return 1;
}

sub delete {
    my ( $self, $schema, $id ) = @_;
    return !!unlink $self->path->child( $self->_id_to_path( $id ) );
}

sub read_schema {
    my ( $self, @schemas ) = @_;
    my %page_schema = (
        type => 'object',
        title => 'Pages',
        required => [qw( slug markdown )],
        'x-id-field' => 'slug',
        'x-view-item-url' => '/{slug}',
        'x-list-columns' => [ 'title', 'slug' ],
        properties => {
            slug => {
                type => 'string',
                'x-order' => 2,
            },
            title => {
                type => 'string',
                'x-order' => 1,
            },
            markdown => {
                type => 'string',
                format => 'markdown',
                'x-html-field' => 'html',
                'x-order' => 3,
            },
            html => {
                type => 'string',
            },
        },
    );
    return @schemas ? \%page_schema : { pages => \%page_schema };
}

sub _id_to_path {
    my ( $self, $id ) = @_;
    # Allow indexes to be created
    if ( $id =~ m{(?:^|\/)index$} ) {
        $id .= '.markdown';
    }
    # Allow full file paths to be created
    elsif ( $id =~ m{\.\w+$} ) {
        $id =~ s{\.\w+$}{.markdown};
    }
    # Anything else should create a file
    else {
        $id .= '.markdown';
    }
    return $id;
}

sub _path_to_id {
    my ( $self, $path ) = @_;
    my $dir = $path->dirname;
    $dir =~ s/^\.//;
    return join '/', grep !!$_, $dir, $path->basename( '.markdown' );
}

sub _read_file {
    my ( $self, $path ) = @_;
    open my $fh, '<', $path or die "Could not open $path for reading: $!";
    local $/;
    return $self->_parse_content( decode( $self->encoding, scalar <$fh>, Encode::FB_CROAK ) );
}

sub _write_file {
    my ( $self, $path, $item ) = @_;
    if ( !-d $path->dirname ) {
        $path->dirname->make_path;
    }
    #; say "Writing to $path:\n$content";
    open my $fh, '>', $path
        or die "Could not open $path for overwriting: $!";
    print $fh encode( $self->encoding, $self->_deparse_content( $item ), Encode::FB_CROAK );
    return;
}

#=sub _parse_content
#
#   my $item = $backend->_parse_content( $path->slurp );
#
# Parse a file's frontmatter and Markdown. Returns a hashref
# ready for use as an item.
#
#=cut

sub _parse_content {
    my ( $self, $content ) = @_;
    my %item;

    my @lines = split /\n/, $content;
    # YAML frontmatter
    if ( @lines && $lines[0] =~ /^---/ ) {

        # The next --- is the end of the YAML frontmatter
        my ( $i ) = grep { $lines[ $_ ] =~ /^---/ } 1..$#lines;

        # If we did not find the marker between YAML and Markdown
        if ( !defined $i ) {
            die qq{Could not find end of YAML front matter (---)\n};
        }

        # Before the marker is YAML
        eval {
            %item = %{ YAML::Load( join "\n", splice( @lines, 0, $i ), "" ) };
            %item = map {$_ => do {
              # YAML.pm 1.29 doesn't parse 'true', 'false' as booleans
              # like the schema suggests: https://yaml.org/spec/1.2/spec.html#id2803629
              my $v = $item{$_};
              $v = JSON::PP::false if $v and $v eq 'false';
              $v = JSON::PP::true if $v and $v eq 'true';
              $v
            }} keys %item;
        };
        if ( $@ ) {
            die qq{Error parsing YAML\n$@};
        }

        # Remove the last '---' mark
        shift @lines;
    }
    # JSON frontmatter
    elsif ( @lines && $lines[0] =~ /^{/ ) {
        my $json;
        if ( $lines[0] =~ /\}$/ ) {
            # The JSON is all on a single line
            $json = shift @lines;
        }
        else {
            # The } on a line by itself is the last line of JSON
            my ( $i ) = grep { $lines[ $_ ] =~ /^}$/ } 0..$#lines;
            # If we did not find the marker between YAML and Markdown
            if ( !defined $i ) {
                die qq{Could not find end of JSON front matter (\})\n};
            }
            $json = join "\n", splice( @lines, 0, $i+1 );
        }
        eval {
            %item = %{ JSON::PP->new()->utf8(0)->decode( $json ) };
        };
        if ( $@ ) {
            die qq{Error parsing JSON: $@\n};
        }
    }

    # The remaining lines are content
    $item{ markdown } = join "\n", @lines, "";
    $item{ html } = $self->markdown_parser->markdown( $item{ markdown } );

    return \%item;
}

sub _deparse_content {
    my ( $self, $item ) = @_;
    my %data =
        map { $_ => do {
        my $v = $item->{ $_ };
          JSON::PP::is_bool($v) ? $v ? 'true' : 'false' : $v
        }}
        grep { !/^(?:markdown|html|slug)$/ }
        keys %$item;
    return ( %data ? YAML::Dump( \%data ) . "---\n" : "") . ( $item->{markdown} // "" );
}

1;
