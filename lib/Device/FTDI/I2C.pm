#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2015 -- leonerd@leonerd.org.uk

package Device::FTDI::I2C;

use strict;
use warnings;
use base qw( Device::FTDI::MPSSE );

use utf8;

our $VERSION = '0.07';

=head1 NAME

=encoding UTF-8

C<Device::FTDI::I2C> - use an I<FDTI> chip to talk the I²C protocol

=head1 DESCRIPTION

This subclass of L<Device::FTDI::MPSSE> provides helpers around the basic
MPSSE to fully implement the I²C protocol.

=cut

use Device::FTDI::MPSSE qw(
    DBUS
    CLOCK_RISING CLOCK_FALLING
);

use Future::Utils qw( repeat );

use constant {
    I2C_SCL     => (1<<0),
    I2C_SDA_OUT => (1<<1),
    I2C_SDA_IN  => (1<<2),
};

use constant { HIGH => 0xff, LOW => 0 };

=head1 CONSTRUCTOR

=cut

=head2 new

    $i2c = Device::FTDI::I2C->new( %args )

This method takes no additional arguments beyond those taken by
L<Device::FTDI::MPSSE/new>.

=cut

sub new
{
    my $class = shift;
    my $self = $class->SUPER::new( @_ );

    $self->set_3phase_clock( 1 );
    $self->set_open_collector( I2C_SCL|I2C_SDA_OUT, 0 );

    $self->set_clock_edges( CLOCK_RISING, CLOCK_FALLING );

    # Idle high
    $self->write_gpio( DBUS, HIGH, I2C_SCL | I2C_SDA_OUT );

    return $self;
}

=head1 METHODS

Any of the following methods documented with a trailing C<< ->get >> call
return L<Future> instances.

=cut

=head2 set_clock_rate

    $i2c->set_clock_rate( $rate )->get

Sets the clock rate for data transfers, in units of bits per second.

=cut

sub set_clock_rate
{
    my $self = shift;
    my ( $rate ) = @_;

    $self->set_clock_divisor( ( 4E6 / $rate ) - 1 );
}

sub i2c_start
{
    my $self = shift;

    my $f;

    # S&H delay
    $self->write_gpio( DBUS, LOW, I2C_SDA_OUT ) for 1 .. 10;
    $f = $self->write_gpio( DBUS, LOW, I2C_SCL ) for 1 .. 10;

    return $f;
}

sub i2c_repeated_start
{
    my $self = shift;

    # Release the lines without appearing as STOP
    $self->write_gpio( DBUS, HIGH, I2C_SDA_OUT ) for 1 .. 10;
    $self->write_gpio( DBUS, HIGH, I2C_SCL ) for 1 .. 10;

    $self->i2c_start;
}

sub i2c_stop
{
    my $self = shift;

    my $f;

    # S&H delay
    $self->write_gpio( DBUS, HIGH, I2C_SCL ) for 1 .. 10;
    $f = $self->write_gpio( DBUS, HIGH, I2C_SDA_OUT ) for 1 .. 10;

    return $f;
}

sub i2c_send
{
    my $self = shift;
    my ( $data ) = @_;

    $self->write_bytes( $data );
    # Release SDA
    $self->write_gpio( DBUS, HIGH, I2C_SDA_OUT );

    $self->read_bits( 1 )
        ->transform( done => sub {
            !( ord $_[0] & 0x80 );
        });
}

sub i2c_recv
{
    my $self = shift;
    my ( $ack ) = @_;

    my $f = $self->read_bytes( 1 );

    $self->write_bits( 1, chr( $ack ? LOW : HIGH ) );
    # Release SDA
    $self->write_gpio( DBUS, HIGH, I2C_SDA_OUT );

    return $f;
}

=head2 write

    $i2c->write( $addr, $data_out )->get

Performs an I²C write operation to the chip at the given (7-bit) address
value.

The device sends a start condition, then a command to address the chip for
writing, followed by the bytes given in the data, and finally a stop
condition.

=cut

sub write
{
    my $self = shift;
    my ( $addr, $data ) = @_;

    $self->i2c_start;

    $self->i2c_send( pack "C", $addr << 1 )
    ->then( sub {
        my ( $ack ) = @_;
        # $ack or die "received ACK from device\n";

        repeat {
            $self->i2c_send( $_[0] )
                ->on_done( sub { my ( $ack ) = @_; } )
        } foreach => [ split m//, $data ];
    })->then( sub {
        $self->i2c_stop;
    });
}

=head2 write_then_read

    $data_in = $i2c->write_then_read( $addr, $data_out, $len_in )->get

Performs an I²C write operation followed by a read operation within the same
transaction to the chip at the given (7-bit) address value.

The device sends a start condition, then a command to address the chip for
writing, followed by the bytes given in the data to output, then a repeated
repeated start condition, then a command to address the chip for reading. It
then attempts to read up to the given number of bytes of input from the chip,
sending an C<ACK> condition to all but the final byte, to which it sends
C<NACK>, and then finally a stop condition.

=cut

sub write_then_read
{
    my $self = shift;
    my ( $addr, $data_out, $len_in ) = @_;

    my $data_in = "";

    $self->i2c_start;

    $self->i2c_send( pack "C", $addr << 1 )
    ->then( sub {
        my ( $ack ) = @_;

        repeat {
            $self->i2c_send( $_[0] )
        } foreach => [ split m//, $data_out ];
    })->then( sub {
        $self->i2c_repeated_start;

        $self->i2c_send( pack "C", 1 | ( $addr << 1 ) );
    })->then( sub {
        my ( $ack ) = @_;

        repeat {
            $self->i2c_recv( $_[0] )
                ->on_done( sub { $data_in .= $_[0] } )
        } foreach => [ ( 1 ) x ( $len_in - 1 ), 0 ]
    })->then( sub {
        $self->i2c_stop
            ->then_done( $data_in );
    });
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;