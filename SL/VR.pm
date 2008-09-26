#=====================================================================
# SQL-Ledger ERP
# Copyright (C) 2006
#
#  Author: DWS Systems Inc.
#     Web: http://www.sql-ledger.com
#
#======================================================================
#
# voucher/batch register backend routines
#
#======================================================================

package VR;


sub create_links {
  my ($self, $myconfig, $form) = @_;

  my $dbh = $form->dbconnect($myconfig);

  # employees
  $form->all_employees($myconfig, $dbh, undef, 0);

  $form->remove_locks($myconfig, $dbh, 'br');
  
  $dbh->disconnect;
  
}


sub edit_batch {
  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect($myconfig);
  
  my $query = qq|SELECT a.batchnumber, a.description, a.transdate
	         FROM br a
		 WHERE a.id = $form->{batchid}|;
  ($form->{batchnumber}, $form->{batchdescription}, $form->{transdate}) = $dbh->selectrow_array($query);

  $dbh->disconnect;

}


sub save_batch {
  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect_noauto($myconfig);
  
  $form->{batchnumber} = $form->update_defaults($myconfig, 'batchnumber', $dbh) unless $form->{batchnumber};
  $transdate = ($form->{transdate}) ? $form->{transdate} : 'current_date';

  my $query = qq|UPDATE br SET
                 batchnumber = |.$dbh->quote($form->{batchnumber}).qq|,
 		 description = |.$dbh->quote($form->{batchdescription}).qq|,
		 transdate = '$transdate'
		 WHERE id = $form->{batchid}|;
  $dbh->do($query) || $form->dberror($query);

  my $rc = $dbh->commit;
  $dbh->disconnect;

  $rc;

}


sub list_batches {
  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect($myconfig);
  my $null;
  my $var;
  
  ($form->{transdatefrom}, $form->{transdateto}) = $form->from_to($form->{year}, $form->{month}, $form->{interval}) if $form->{year} && $form->{month};
 
  my $query = qq|SELECT a.id, a.batch, a.batchnumber, a.description,
                 a.transdate, a.apprdate, a.amount,
		 e.name AS employee, m.name AS manager
	         FROM br a
	      LEFT JOIN employee e ON (a.employee_id = e.id)
	      LEFT JOIN employee m ON (a.managerid = m.id)
	      |;

  my %ordinal = ( id => 1,
                  batchnumber => 2,
		  description => 3,
		  transdate => 4,
		  apprdate => 5,
		  employee => 7,
		  manager => 8
		);

  
  my @a = (batchnumber, transdate, apprdate);
  push @a, "employee" if $form->{l_employee};
  push @a, "manager" if $form->{l_manager};
  my $sortorder = $form->sort_order(\@a, \%ordinal);

  my $where = "1 = 1";
  $where .= " AND a.batch = '$form->{batch}'" if $form->{batch};

  if ($myconfig->{role} eq 'user') {
    ($null, $var) = $form->get_employee($dbh);
    $where .= " AND a.employee_id = $var";
  } else {
    if ($form->{employee}) {
      ($null, $var) = split /--/, $form->{employee};
      $where .= " AND a.employee_id = $var";
    }
  }

  if ($form->{batchnumber}) {
    $var = $form->like(lc $form->{batchnumber});
    $where .= " AND lower(a.batchnumber) LIKE '$var'";
  }
  if ($form->{description}) {
    $var = $form->like(lc $form->{description});
    $where .= " AND lower(a.description) LIKE '$var'";
  }

  $where .= " AND a.transdate >= '$form->{transdatefrom}'" if $form->{transdatefrom};
  $where .= " AND a.transdate <= '$form->{transdateto}'" if $form->{transdateto};
  
  if (! $form->{l_apprdate}) {
    $where .= " AND a.apprdate IS NULL";
  }

  $query .= "
             WHERE $where
             ORDER by $sortorder";

  my $sth = $dbh->prepare($query);
  $sth->execute || $form->dberror($query);

  while (my $ref = $sth->fetchrow_hashref(NAME_lc)) {
    push @{ $form->{transactions} }, $ref;
  }
  
  $sth->finish;
  $dbh->disconnect;

}


sub post_transaction {
  my ($self, $myconfig, $form) = @_;

  my $dbh = $form->dbconnect_noauto($myconfig);
  my $query;
  
  $form->{pending} = 1;
  
  if (! $form->{batchid}) {

    $form->{batchnumber} = $form->update_defaults($myconfig, 'batchnumber', $dbh) unless $form->{batchnumber};
    
    my $uid = localtime;
    $uid .= $$;
    $query = qq|INSERT INTO br (batchnumber, batch, employee_id)
                VALUES ('$uid', '$form->{batch}',
		    (SELECT id FROM employee
		     WHERE login = '$form->{login}'))|;
    $dbh->do($query) || $form->dberror($query);

    $query = qq|SELECT id FROM br
                WHERE batchnumber = '$uid'|;
    ($form->{batchid}) = $dbh->selectrow_array($query);
    
    $query = qq|UPDATE br SET
                batchnumber = |.$dbh->quote($form->{batchnumber}).qq|,
		description = |.$dbh->quote($form->{batchdescription}).qq|,
		transdate = '$form->{transdate}'
		WHERE id = $form->{batchid}|;
    $dbh->do($query) || $form->dberror($query);
  }


  if ($form->{batch} eq 'ap') {
    AA->post_transaction($myconfig, $form, $dbh);
  }
  if ($form->{batch} eq 'gl') {
    GL->post_transaction($myconfig, $form, $dbh);
  }
  if ($form->{batch} eq 'payment') {
    &{ "CP::post_$form->{payment}" }("", $myconfig, $form, $dbh);
  }
  
  my $rc = $dbh->commit;
  $dbh->disconnect;

  $rc;

}


sub list_vouchers {
  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect($myconfig);

  my $ml = 1;
  
  my $query = qq|SELECT batchnumber, description, transdate, apprdate, batch
                 FROM br
		 WHERE id = $form->{batchid}|;
  ($form->{batchnumber}, $form->{batchdescription}, $form->{transdate}, $form->{apprdate}, $form->{batch}) = $dbh->selectrow_array($query);

  $form->remove_locks($myconfig, $dbh, 'br');
  $form->create_lock($myconfig, $dbh, $form->{batchid}, 'br');
  
  my %ordinal = ( id => 1,
                  invnumber => 2,
		  name => 3,
		  vendornumber => 4,
		  vouchernumber => 6
		);

  my @a = (vouchernumber);
  my $sortorder = $form->sort_order(\@a, \%ordinal);

  if ($form->{batch} eq 'ap') {
    
    $query = qq|SELECT a.id, a.invnumber, v.name, v.vendornumber,
                a.amount, vr.vouchernumber
                FROM vr
		JOIN ap a ON (a.id = vr.trans_id)
		JOIN vendor v ON (v.id = a.vendor_id)
		WHERE vr.br_id = $form->{batchid}
                ORDER by $sortorder|;

  } elsif ($form->{batch} eq 'payment') {

    $form->{vc} = "vendor";
    $table = "ap";

    $query = qq|SELECT vr.id, vr.id AS voucherid, v.name,
                v.$form->{vc}number, sum(ac.amount) * $ml AS amount,
		vr.vouchernumber, a.$form->{vc}_id
                FROM acc_trans ac
		JOIN vr ON (vr.id = ac.vr_id AND vr.trans_id = ac.trans_id)
		JOIN chart c ON (c.id = ac.chart_id)
		JOIN $table a ON (a.id = ac.trans_id)
		JOIN $form->{vc} v ON (v.id = a.$form->{vc}_id)
		WHERE vr.br_id = $form->{batchid}
		AND c.link LIKE '%AP_paid%'
		GROUP BY vr.id, v.name, v.$form->{vc}number, vr.vouchernumber,
		a.$form->{vc}_id
                ORDER by $sortorder|;
		
  } elsif ($form->{batch} eq 'payment_reversal') {

    $form->{vc} = "vendor";
    $table = "ap";

    $ml = -1;

    $query = qq|SELECT vr.id, vr.id AS voucherid, v.name,
                v.$form->{vc}number, sum(ac.amount) * $ml AS amount,
		vr.vouchernumber, a.$form->{vc}_id, ac.source
                FROM acc_trans ac
		JOIN vr ON (vr.id = ac.vr_id AND vr.trans_id = ac.trans_id)
		JOIN chart c ON (c.id = ac.chart_id)
		JOIN $table a ON (a.id = ac.trans_id)
		JOIN $form->{vc} v ON (v.id = a.$form->{vc}_id)
		WHERE vr.br_id = $form->{batchid}
		AND c.link LIKE '%AP_paid%'
		GROUP BY vr.id, v.name, v.$form->{vc}number, vr.vouchernumber,
		a.$form->{vc}_id, ac.source
                ORDER by $sortorder|;

  } elsif ($form->{batch} eq 'gl') {
    
    $query = qq|SELECT g.id, g.reference AS invnumber, g.description AS name,
		SUM(ac.amount) AS amount, vr.id AS voucherid, vr.vouchernumber
                FROM acc_trans ac
		JOIN gl g ON (g.id = ac.trans_id)
		JOIN vr ON (vr.trans_id = g.id)
		WHERE vr.br_id = $form->{batchid}
		AND ac.amount >= 0
		GROUP BY g.id, g.reference, g.description, vr.id,
		vr.vouchernumber
                ORDER by $sortorder|;
		 
  }

  my $sth = $dbh->prepare($query);
  $sth->execute || $form->dberror($query);

  while (my $ref = $sth->fetchrow_hashref(NAME_lc)) {
    push @{ $form->{transactions} }, $ref;
  }
  
  $sth->finish;
  $dbh->disconnect;

}


sub delete_transaction {
  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect_noauto($myconfig);
  my $query;
  
  my $table = "ap";
  $table = "gl" if $form->{batch} eq 'gl';
  
  $query = qq|SELECT amount
              FROM $table
	      WHERE id = $form->{id}|;
  if ($form->{batch} eq 'gl') {
    $query = qq|SELECT SUM(amount)
                FROM acc_trans
		WHERE amount > 0
		AND trans_id = $form->{id}|;
  }
  my ($amount) = $dbh->selectrow_array($query);
  
  $query = qq|DELETE FROM $table
	      WHERE id = $form->{id}|;
  $dbh->do($query) || $form->dberror($query);

  for (qw(vr acc_trans)) {
    $query = qq|DELETE FROM $_
		WHERE trans_id = $form->{id};|;
  }
  $dbh->do($query) || $form->dberror($query);
  
  $form->update_balance($dbh,
			'br',
			'amount',
			qq|id = $form->{batchid}|,
			$amount * -1);

  $form->remove_locks($myconfig, $dbh, $table);
  
  my $rc = $dbh->commit;
  $dbh->disconnect;

  $rc;

}


sub delete_payment_reversal {
  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect_noauto($myconfig);
  my $query;
 
  $query = qq|SELECT ac.trans_id, ac.amount * -1
              FROM acc_trans ac
	      JOIN vr ON (vr.id = ac.vr_id)
	      JOIN chart c ON (c.id = ac.chart_id)
	      WHERE vr_id = $form->{id}
	      AND ac.approved = '0'
	      AND c.link LIKE '%AP_paid%'|;
  my ($trans_id, $amount) = $dbh->selectrow_array($query);
  
  $query = qq|DELETE FROM vr
              WHERE id = $form->{id}|;
  $dbh->do($query) || $form->dberror($query);
	      
  $query = qq|DELETE FROM acc_trans
              WHERE vr_id = $form->{id}|;
  $dbh->do($query) || $form->dberror($query);
  
  $form->update_balance($dbh,
			'br',
			'amount',
			qq|id = $form->{batchid}|,
			$amount * -1);

  if ($trans_id) {
    $form->update_balance($dbh,
			  'ap',
			  'paid',
			  qq|id = $trans_id|,
			  $amount);

    $query = qq|UPDATE ap SET
                onhold = '0'
		WHERE id = $trans_id|;
    $dbh->do($query) || $form->dberror($query);
		
  }
  
  $form->remove_locks($myconfig, $dbh, ap);
  
  my $rc = $dbh->commit;
  $dbh->disconnect;

  $rc;

}


sub delete_batch {
  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect_noauto($myconfig);
  
  my $query = qq|SELECT vr.id, vr.trans_id
                 FROM vr
	         WHERE vr.br_id = $form->{batchid}|;
  my $sth = $dbh->prepare($query);
  $sth->execute || $form->dberror($query);

  my $dth;
  my $pth;
  my $ath;
  my $vth;

  my $table = "ap";
  $table = "gl" if $form->{batch} eq 'gl';
  
  if ($form->{batch} eq 'payment') {
    my %defaults = $form->get_defaults($dbh, \@{['fx%_accno_id']});
    
    $query = qq|SELECT SUM(ac.amount)
		FROM acc_trans ac
		JOIN chart c ON (c.id = ac.chart_id)
		WHERE ac.vr_id = ?
		AND ac.trans_id = ?
		AND ac.approved = '0'
		AND (c.link LIKE '%AP_paid%'
		     OR c.link LIKE '%AP_discount%')
		AND NOT (ac.chart_id = $defaults{fxgain_accno_id}
		      OR ac.chart_id = $defaults{fxloss_accno_id})
		|;
    $pth = $dbh->prepare($query) || $form->dberror($query);
    
    $query = qq|DELETE FROM acc_trans
		WHERE approved = '0'
		AND vr_id = ?
		AND trans_id = ?|;
    $vth = $dbh->prepare($query) || $form->dberror($query);
   
  } else {
    $query = qq|DELETE FROM $table
                WHERE approved = '0'
		AND id = ?|;
    $dth = $dbh->prepare($query) || $form->dberror($query);

    $query = qq|DELETE FROM acc_trans
		WHERE approved = '0'
		AND trans_id = ?|;
    $ath = $dbh->prepare($query) || $form->dberror($query);

  }
  
  while (my ($voucherid, $trans_id) = $sth->fetchrow_array) {

    if ($pth) {
      $pth->execute($voucherid, $trans_id);
      ($amount) = $pth->fetchrow_array;
      $pth->finish;
      $amount = $form->round_amount($amount * -1, $form->{precision});

      $form->update_balance($dbh,
                            $table,
			    'paid',
			    qq|id = $trans_id|,
			    $amount);
    }

    if ($dth) {
      $dth->execute($trans_id);
      $dth->finish;
    }
    
    if ($ath) {
      $ath->execute($trans_id);
      $ath->finish;
    }

    if ($vth) {
      $vth->execute($voucherid, $trans_id);
      $vth->finish;
    }
    
  }
  $sth->finish;
 
  $query = qq|DELETE FROM br
	      WHERE id = $form->{batchid}|;
  $dbh->do($query) || $form->dberror($query);
  
  $form->remove_locks($myconfig, $dbh, 'br');
  
  my $rc = $dbh->commit;
  $dbh->disconnect;

  $rc;

}


sub post_batch {
  my ($self, $myconfig, $form, $dbh) = @_;

  my $disconnect;
  
  # connect to database
  if (! $dbh) {
    $dbh = $form->dbconnect_noauto($myconfig);
    $disconnect = 1;
  }

  my $query = qq|SELECT trans_id, id
                 FROM vr
	         WHERE br_id = $form->{batchid}|;
  my $sth = $dbh->prepare($query);
  $sth->execute || $form->dberror($query);

  my $table = "ap";
  $table = "gl" if $form->{batch} eq 'gl';
  
  my $ath;
  my $gth;
  my $rth;
  
  if ($form->{batch} =~ /payment/) {
    $query = qq|UPDATE acc_trans SET
		approved = '1'
		WHERE trans_id = ?
		AND vr_id = ?|;
    $ath = $dbh->prepare($query) || $form->dberror($query);
  } else {
    $query = qq|UPDATE acc_trans SET
		approved = '1'
		WHERE trans_id = ?|;
    $ath = $dbh->prepare($query) || $form->dberror($query);
    
    $query = qq|UPDATE $table SET
		approved = '1'
		WHERE id = ?|;
    $gth = $dbh->prepare($query) || $form->dberror($query);
  }
  
  # if payment_reversal undo onhold
  if ($form->{batch} eq 'payment_reversal') {
    $query = qq|UPDATE ap SET
                onhold = '0'
		WHERE id = ?|;
    $rth = $dbh->prepare($query) || $form->dberror($query);
  }
  
  while (my ($trans_id, $id) = $sth->fetchrow_array) {

    if ($form->{batch} =~ /payment/) {
      $ath->execute($trans_id, $id);
      $ath->finish;
      
      if ($rth) {
	$rth->execute($trans_id);
	$rth->finish;
      }

    } else {
      $ath->execute($trans_id);
      $ath->finish;
      
      $gth->execute($trans_id);
      $gth->finish;
    }

  }
  $sth->finish;
 
  $query = qq|UPDATE br SET
              apprdate = current_date
	      WHERE id = $form->{batchid}|;
  $dbh->do($query) || $form->dberror($query);

  $form->remove_locks($myconfig, $dbh, 'br');
  
  my $rc = $dbh->commit;
    
  if ($disconnect) {
    $dbh->disconnect;
  }

  $rc;

}


sub _post_batches {
  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect_noauto($myconfig);
  
  my $query = qq|SELECT id, batch
                 FROM br
	         WHERE id = ?|;
  my $sth = $dbh->prepare($query) || $form->dberror($query);

  for (1 .. $form->{rowcount}) {
    if ($form->{"checked_$_"}) {
      $sth->execute($form->{"id_$_"});
      ($form->{batchid}, $form->{batch}) = $sth->fetchrow_array;
      $sth->finish;

      &post_batch("", $myconfig, $form, $dbh);
    }

  }
  
  $dbh->disconnect;

}


sub payment_reversal {
  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect($myconfig);

  my $query = qq|SELECT accno, description
                 FROM chart
		 WHERE link LIKE '%AP_paid%'
		 ORDER BY accno|;
  my $sth = $dbh->prepare($query);
  $sth->execute || $form->dberror($query);

  my $ref;
  while ($ref = $sth->fetchrow_hashref(NAME_lc)) {
    push @{ $form->{all_accounts} }, $ref;
  }
  $sth->finish;

  if ($form->{id}) {
    # get payment account and vouchernumber
    $query = qq/SELECT ac.source, ac.memo,
                (SELECT c.accno || '--' || c.description
                 FROM chart c
                 WHERE ac.chart_id = c.id)
                FROM acc_trans ac
		JOIN vr ON (vr.id = ac.vr_id)
		JOIN chart c ON (c.id = ac.chart_id)
		WHERE vr.id = $form->{id}
		AND c.link LIKE '%AP_paid%'/;
    ($form->{source}, $form->{memo}, $form->{account}) = $dbh->selectrow_array($query);
  }
  
  $dbh->disconnect;

}


sub post_payment_reversal {
  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect_noauto($myconfig);

  my $query;
  
  $form->{vouchernumber} = $form->update_defaults($myconfig, 'vouchernumber', $dbh) unless $form->{vouchernumber};
  
  if ($form->{id}) {

    $query = qq|SELECT ac.amount
		FROM acc_trans ac
		JOIN vr ON (vr.id = ac.vr_id)
		JOIN chart c ON (c.id = ac.chart_id)
		WHERE vr_id = $form->{id}
		AND c.link LIKE '%AP_paid%'|;
    my ($amount) = $dbh->selectrow_array($query);
    
    # update balance for batch
    $form->update_balance($dbh,
			  'br',
			  'amount',
			  qq|id = $form->{batchid}|,
			  $amount);

    $query = qq|DELETE FROM acc_trans
                WHERE vr_id = $form->{id}|;
    $dbh->do($query) || $form->dberror($query);
    
  } else {
    $query = qq|SELECT nextval('id')|;
    ($form->{id}) = $dbh->selectrow_array($query);
  }
  
  my $accno = $form->{account};
  $accno =~ s/--.*//g;
  
  my $query = qq|SELECT id FROM chart
                 WHERE accno = '$accno'|;
  my ($chart_id) = $dbh->selectrow_array($query);
  
  $query = qq|SELECT trans_id, chart_id, amount, fx_transaction
              FROM acc_trans
              WHERE source = ?
	      AND chart_id = $chart_id|;
  my $sth = $dbh->prepare($query) || $form->dberror($query);
  $sth->execute($form->{source}) || $form->dberror($query);
  
  # create batch
  if (! $form->{batchid}) {

    $form->{batchnumber} = $form->update_defaults($myconfig, 'batchnumber', $dbh) unless $form->{batchnumber};
    
    my $uid = localtime;
    $uid .= $$;
    $query = qq|INSERT INTO br (batchnumber, batch, employee_id)
                VALUES ('$uid', '$form->{batch}',
		    (SELECT id FROM employee
		     WHERE login = '$form->{login}'))|;
    $dbh->do($query) || $form->dberror($query);

    $query = qq|SELECT id FROM br
                WHERE batchnumber = '$uid'|;
    ($form->{batchid}) = $dbh->selectrow_array($query);
    
    $query = qq|UPDATE br SET
                batchnumber = |.$dbh->quote($form->{batchnumber}).qq|,
		description = |.$dbh->quote($form->{batchdescription}).qq|,
		transdate = '$form->{transdate}'
		WHERE id = $form->{batchid}|;
    $dbh->do($query) || $form->dberror($query);
  } 
  
  $query = qq|INSERT INTO acc_trans (trans_id, chart_id, amount, transdate,
              source, memo, approved, vr_id, fx_transaction)
              VALUES (?, ?, ?, '$form->{transdate}',|
	      .$dbh->quote($form->{source}).qq|,|
	      .$dbh->quote($form->{memo}).qq|, '0', $form->{id}, ?)|;
  my $pth = $dbh->prepare($query) || $form->dberror($query);

  # AP account
  $query = qq|SELECT ac.chart_id
              FROM acc_trans ac
              JOIN chart c ON (c.id = ac.chart_id)
              WHERE trans_id = ?
	      AND c.link = 'AP'|;
  my $ath = $dbh->prepare($query) || $form->dberror($query);

  # on hold
  $query = qq|UPDATE ap SET
              onhold = '1'
	      WHERE id = ?|;
  my $oth = $dbh->prepare($query) || $form->dberror($query);
  
  # voucher
  $query = qq|INSERT INTO vr (id, br_id, trans_id, vouchernumber) VALUES (
              $form->{id}, $form->{batchid}, ?, '$form->{vouchernumber}')|;
  my $vth = $dbh->prepare($query) || $form->dberror($query);

 
  while (my $ref = $sth->fetchrow_hashref(NAME_lc)) {
    
    # get AP account
    $ath->execute($ref->{trans_id});
    my ($ap_id) = $ath->fetchrow_array;
    $ath->finish;
    
    if ($ap_id) {
    
      # create voucher
      $vth->execute($ref->{trans_id});
      $vth->finish;

      # post payment reversal
      $pth->execute($ref->{trans_id}, $chart_id, $ref->{amount} * -1, $ref->{fx_transaction});
      $pth->finish;
      
      # post offsetting AP
      $pth->execute($ref->{trans_id}, $ap_id, $ref->{amount}, $ref->{fx_transaction});
      $pth->finish;

      # update balance for batch
      $form->update_balance($dbh,
			    'br',
			    'amount',
			    qq|id = $form->{batchid}|,
			    $ref->{amount});

    }

    # update AP
    $form->update_balance($dbh,
			  'ap',
			  'paid',
			  qq|id = $ref->{trans_id}|,
			  $ref->{amount} * -1);

    # put transaction on hold
    $oth->execute($ref->{trans_id});

  }
  $sth->finish;

  my $rc = $dbh->commit;
  $dbh->disconnect;

  $rc;
  
}

1;

